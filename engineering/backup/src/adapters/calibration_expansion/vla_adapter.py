from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
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


class VLAAdapterModelServer(PredictModelServer):
    """Thin wrapper around the official VLA-Adapter inference implementation."""

    def __init__(
        self,
        source_checkout: str,
        source_commit: str,
        checkpoint_dir: str,
        checkpoint_revision: str,
        unnorm_key: str,
        chunk_size: int = 8,
        **kwargs: Any,
    ) -> None:
        super().__init__(chunk_size=chunk_size, **kwargs)

        source = Path(source_checkout)
        checkpoint = Path(checkpoint_dir)

        if not source.is_dir():
            raise RuntimeError(f"VLA-Adapter source checkout missing: {source}")

        if not checkpoint.is_dir():
            raise RuntimeError(f"VLA-Adapter checkpoint directory missing: {checkpoint}")

        current_commit = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            text=True,
        ).strip()

        if current_commit != source_commit:
            raise RuntimeError(
                f"source revision mismatch: {current_commit} != {source_commit}"
            )

        marker = checkpoint / ".calexp_hf_revision"
        if not marker.is_file():
            raise RuntimeError(f"missing checkpoint revision marker: {marker}")

        actual_revision = marker.read_text().strip()
        if actual_revision != checkpoint_revision:
            raise RuntimeError(
                f"checkpoint revision mismatch: "
                f"{actual_revision} != {checkpoint_revision}"
            )

        sys.path.insert(0, str(source))

        from experiments.robot.openvla_utils import (
            get_action_head,
            get_processor,
            get_proprio_projector,
            resize_image_for_policy,
        )
        from experiments.robot.robot_utils import (
            get_action,
            get_image_resize_size,
            get_model,
            invert_gripper_action,
            normalize_gripper_action,
            set_seed_everywhere,
        )

        self._get_action = get_action
        self._resize_image_for_policy = resize_image_for_policy
        self._normalize_gripper_action = normalize_gripper_action
        self._invert_gripper_action = invert_gripper_action

        self.cfg = SimpleNamespace(
            model_family="openvla",
            pretrained_checkpoint=str(checkpoint),

            use_l1_regression=True,
            use_diffusion=False,

            use_minivlm=True,
            use_film=False,
            use_pro_version=True,

            num_images_in_input=2,
            use_proprio=True,

            center_crop=True,
            num_open_loop_steps=8,

            unnorm_key=unnorm_key,

            load_in_8bit=False,
            load_in_4bit=False,

            num_diffusion_steps=50,
            num_diffusion_steps_train=50,
            num_diffusion_steps_inference=50,

            lora_rank=32,

            save_version="vla-adapter",
            phase="Inference",
        )

        set_seed_everywhere(7)

        self.model = get_model(self.cfg)
        self.model.set_version(self.cfg.save_version)

        self.proprio_projector = get_proprio_projector(
            self.cfg,
            self.model.llm_dim,
            proprio_dim=8,
        )

        self.action_head = get_action_head(
            self.cfg,
            self.model.llm_dim,
        )

        self.processor = get_processor(self.cfg)

        if (
            self.cfg.unnorm_key not in self.model.norm_stats
            and f"{self.cfg.unnorm_key}_no_noops" in self.model.norm_stats
        ):
            self.cfg.unnorm_key = f"{self.cfg.unnorm_key}_no_noops"

        if self.cfg.unnorm_key not in self.model.norm_stats:
            raise RuntimeError(
                f"unnorm key absent from norm_stats: {self.cfg.unnorm_key}"
            )

        self.resize_size = get_image_resize_size(self.cfg)

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

    def predict(self, obs: Observation, ctx: SessionContext) -> Action:
        images = obs.get("images", {})

        if "agentview" not in images:
            raise KeyError("missing agentview image")

        if "wrist" not in images:
            raise KeyError("missing wrist image")

        if "states" not in obs:
            raise KeyError("missing LIBERO state")

        state = np.asarray(obs["states"], dtype=np.float32).reshape(-1)

        if state.shape != (8,):
            raise ValueError(f"expected LIBERO 8-D state, got {state.shape}")

        full = self._resize_image_for_policy(
            np.asarray(images["agentview"]),
            self.resize_size,
        )

        wrist = self._resize_image_for_policy(
            np.asarray(images["wrist"]),
            self.resize_size,
        )

        upstream_obs = {
            "full_image": full,
            "wrist_image": wrist,
            "state": state,
        }

        actions = self._get_action(
            self.cfg,
            self.model,
            upstream_obs,
            str(obs.get("task_description", "")),
            processor=self.processor,
            action_head=self.action_head,
            proprio_projector=self.proprio_projector,
            noisy_action_projector=None,
            use_film=False,
            use_minivlm=True,
        )

        actions = np.asarray(actions, dtype=np.float32)

        if actions.ndim != 2:
            raise ValueError(
                f"expected action chunk [T,7], got {actions.shape}"
            )

        if actions.shape[1] != 7:
            raise ValueError(
                f"expected 7 action dimensions, got {actions.shape}"
            )

        # Exact official LIBERO post-processing.
        actions = self._normalize_gripper_action(
            actions,
            binarize=True,
        )

        actions = self._invert_gripper_action(actions)

        if not np.isfinite(actions).all():
            raise ValueError("non-finite VLA-Adapter action")

        return {"actions": actions}


if __name__ == "__main__":
    from vla_eval.model_servers.serve import run_server
    run_server(VLAAdapterModelServer)
