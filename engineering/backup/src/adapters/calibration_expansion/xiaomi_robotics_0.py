from __future__ import annotations

import hashlib
import json
from typing import Any

import numpy as np

from vla_eval.model_servers.base import SessionContext
from vla_eval.model_servers.predict import PredictModelServer
from vla_eval.specs import (
    GRIPPER_CLOSE_POS,
    IMAGE_RGB,
    LANGUAGE,
    POSITION_DELTA,
    ROTATION_AA,
    STATE_EEF_POS_AA_GRIP,
    DimSpec,
)
from vla_eval.types import Action, Observation


class XiaomiRobotics0ModelServer(PredictModelServer):
    """Xiaomi-Robotics-0 LIBERO adapter.

    The adapter follows the official LIBERO inference contract:

    - agentview + wrist RGB
    - LIBERO 8-D proprio: [eef_pos3, axis_angle3, gripper2]
    - zero-pad state to Xiaomi's 32-D representation
    - robot_type=libero_all
    - model produces a 30-step padded action chunk
    - execute the first 10 steps and first 7 action dimensions

    No action/gripper remapping is applied after decode_action because
    the official LIBERO evaluator sends those first 7 decoded dimensions
    directly to env.step().
    """

    def __init__(
        self,
        model_path: str = "XiaomiRobotics/Xiaomi-Robotics-0-LIBERO",
        revision: str | None = None,
        robot_type: str = "libero_all",
        device: str = "cuda",
        attn_implementation: str = "flash_attention_2",
        chunk_size: int = 10,
        **kwargs: Any,
    ) -> None:
        super().__init__(chunk_size=chunk_size, **kwargs)

        import torch
        from transformers import AutoModel, AutoProcessor

        self.model_path = model_path
        self.revision = revision
        self.robot_type = robot_type
        self._torch = torch

        if device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("Xiaomi-Robotics-0 requires a CUDA GPU for qualification")

        self._device = torch.device(device)

        load_kwargs: dict[str, Any] = {
            "trust_remote_code": True,
            "dtype": torch.bfloat16,
        }

        if revision:
            load_kwargs["revision"] = revision

        if attn_implementation:
            load_kwargs["attn_implementation"] = attn_implementation

        self._model = AutoModel.from_pretrained(
            model_path,
            **load_kwargs,
        ).to(self._device).eval()

        processor_kwargs: dict[str, Any] = {
            "trust_remote_code": True,
            "use_fast": False,
        }

        if revision:
            processor_kwargs["revision"] = revision

        self._processor = AutoProcessor.from_pretrained(
            model_path,
            **processor_kwargs,
        )

    def get_observation_params(self) -> dict[str, Any]:
        return {
            "send_wrist_image": True,
            "send_state": True,
        }

    def get_action_spec(self) -> dict[str, DimSpec]:
        return {
            "position": POSITION_DELTA,
            "rotation": ROTATION_AA,
            "gripper": GRIPPER_CLOSE_POS,
        }

    def get_observation_spec(self) -> dict[str, DimSpec]:
        return {
            "agentview": IMAGE_RGB,
            "wrist": IMAGE_RGB,
            "state": STATE_EEF_POS_AA_GRIP,
            "language": LANGUAGE,
        }

    @staticmethod
    def _to_pil(value: Any):
        from PIL import Image

        if isinstance(value, Image.Image):
            return value.convert("RGB")

        arr = np.asarray(value)

        if arr.dtype != np.uint8:
            arr = np.clip(arr, 0, 255).astype(np.uint8)

        return Image.fromarray(arr).convert("RGB")

    @staticmethod
    def _stable_seed(payload: dict[str, Any]) -> int:
        """Match Xiaomi's deterministic observation-hash seed contract."""

        from PIL import Image

        def encoder(obj: Any):
            if isinstance(obj, np.ndarray):
                return {
                    "__type__": "numpy",
                    "dtype": str(obj.dtype),
                    "shape": obj.shape,
                    "data": obj.tobytes().hex(),
                }

            if isinstance(obj, Image.Image):
                return {
                    "__type__": "PIL.Image",
                    "mode": obj.mode,
                    "size": obj.size,
                    "content_hash": hashlib.md5(obj.tobytes()).hexdigest(),
                }

            if isinstance(obj, set):
                return sorted(obj)

            raise TypeError(f"Unsupported seed payload type: {type(obj)!r}")

        canonical = json.dumps(
            payload,
            default=encoder,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )

        digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        return int(digest, 16) % (2 ** 32)

    def predict(self, obs: Observation, ctx: SessionContext) -> Action:
        torch = self._torch

        images = obs.get("images", {})

        if "agentview" not in images:
            raise KeyError("missing agentview image")

        if "wrist" not in images:
            raise KeyError("missing wrist image")

        if "states" not in obs:
            raise KeyError("missing LIBERO proprioceptive state")

        base = self._to_pil(images["agentview"])
        wrist = self._to_pil(images["wrist"])

        state8 = np.asarray(
            obs["states"],
            dtype=np.float32,
        ).reshape(-1)

        if state8.shape != (8,):
            raise ValueError(
                f"expected LIBERO 8-D state, got {state8.shape}"
            )

        # Exact official LIBERO client contract:
        # 8 active state dims + 24 zero-padding dims.
        state32 = np.concatenate(
            [state8, np.zeros(24, dtype=np.float32)]
        )

        language = str(
            obs.get("task_description", "")
        ).capitalize()

        seed_payload = {
            "task_id": self.robot_type,
            "state": state32,
            "base": base,
            "wrist_left": wrist,
            "language": language,
        }

        seed = self._stable_seed(seed_payload)

        # Official evaluator adds the period after deriving the seed.
        language = language + "."

        instruction = (
            "<|im_start|>user\n"
            "The following observations are captured from multiple views.\n"
            "# Base View\n"
            "<|vision_start|><|image_pad|><|vision_end|>\n"
            "# Left-Wrist View\n"
            "<|vision_start|><|image_pad|><|vision_end|>\n"
            "Generate robot actions for the task:\n"
            f"{language} /no_cot<|im_end|>\n"
            "<|im_start|>assistant\n"
            "<cot></cot><|im_end|>\n"
        )

        inputs = self._processor(
            text=[instruction],
            images=[base, wrist],
            videos=None,
            padding=True,
            return_tensors="pt",
        ).to(self._device)

        inputs["seed"] = seed

        inputs["state"] = torch.from_numpy(
            state32
        ).to(
            self._device,
            dtype=self._model.dtype,
        ).view(1, 1, -1)

        inputs["action_mask"] = self._processor.get_action_mask(
            self.robot_type
        ).to(
            self._device,
            dtype=self._model.dtype,
        )

        with torch.no_grad():
            outputs = self._model(**inputs)

        decoded = self._processor.decode_action(
            outputs.actions,
            robot_type=self.robot_type,
        )

        if hasattr(decoded, "detach"):
            decoded = decoded.detach().cpu().numpy()

        actions = np.asarray(
            decoded,
            dtype=np.float32,
        )

        # Standard HF output is [B, T, D].
        if actions.ndim == 3:
            if actions.shape[0] != 1:
                raise ValueError(
                    f"unexpected batch dimension: {actions.shape}"
                )
            actions = actions[0]

        if actions.ndim != 2:
            raise ValueError(
                f"expected 2-D action chunk, got {actions.shape}"
            )

        if actions.shape[1] < 7:
            raise ValueError(
                f"expected >=7 action dims, got {actions.shape}"
            )

        # Official LIBERO client uses the first seven control dimensions.
        # PredictModelServer trims the time axis to chunk_size=10.
        actions = actions[:, :7]

        if not np.isfinite(actions).all():
            raise ValueError("non-finite Xiaomi action")

        return {"actions": actions}


if __name__ == "__main__":
    from vla_eval.model_servers.serve import run_server

    run_server(XiaomiRobotics0ModelServer)
