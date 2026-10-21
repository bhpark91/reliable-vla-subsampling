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
    DimSpec,
)
from vla_eval.types import Action, Observation


class UniVLAOpenDriveLabModelServer(PredictModelServer):
    """OpenDriveLab UniVLA LIBERO adapter.

    Exact upstream behavior preserved:

    - one third-person RGB image only
    - no wrist input
    - no proprio input to the VLA
    - latent-action autoregressive history
    - ActionDecoder window_size=12
    - temporal aggregation produces ONE 7-D action per observation
    - LIBERO action-stat unnormalization
    - official gripper normalize + sign inversion

    Important:
    Do NOT use PredictModelServer chunk buffering for UniVLA.
    The upstream ActionDecoder already performs its own temporal aggregation.
    """

    LATENT_ACTION_BASE_ID = 32001
    LATENT_ACTION_VOCAB_SIZE = 32

    def __init__(
        self,
        source_checkout: str,
        source_commit: str,
        checkpoint_dir: str,
        checkpoint_revision: str,
        unnorm_key: str,
        window_size: int = 12,
        **kwargs: Any,
    ) -> None:
        # UniVLA outputs exactly one temporally aggregated action per call.
        super().__init__(chunk_size=None, **kwargs)

        import torch

        source = Path(source_checkout)
        checkpoint = Path(checkpoint_dir)

        if not source.is_dir():
            raise RuntimeError(
                f"UniVLA source checkout missing: {source}"
            )

        if not checkpoint.is_dir():
            raise RuntimeError(
                f"UniVLA checkpoint directory missing: {checkpoint}"
            )

        current_commit = subprocess.check_output(
            [
                "git",
                "-C",
                str(source),
                "rev-parse",
                "HEAD",
            ],
            text=True,
        ).strip()

        if current_commit != source_commit:
            raise RuntimeError(
                f"source revision mismatch: "
                f"{current_commit} != {source_commit}"
            )

        marker = checkpoint / ".calexp_hf_revision"

        if not marker.is_file():
            raise RuntimeError(
                f"missing checkpoint revision marker: {marker}"
            )

        actual_revision = marker.read_text().strip()

        if actual_revision != checkpoint_revision:
            raise RuntimeError(
                f"checkpoint revision mismatch: "
                f"{actual_revision} != {checkpoint_revision}"
            )

        action_decoder_path = checkpoint / "action_decoder.pt"

        if not action_decoder_path.is_file():
            raise RuntimeError(
                f"missing official action_decoder.pt: "
                f"{action_decoder_path}"
            )

        sys.path.insert(0, str(source))

        from experiments.robot.openvla_utils import get_processor

        from experiments.robot.robot_utils import (
            get_image_resize_size,
            get_latent_action,
            get_model,
            invert_gripper_action,
            normalize_gripper_action,
            set_seed_everywhere,
        )

        from prismatic.models.policy.transformer_utils import MAPBlock

        self._torch = torch
        self._MAPBlock = MAPBlock

        self._get_latent_action = get_latent_action
        self._normalize_gripper_action = normalize_gripper_action
        self._invert_gripper_action = invert_gripper_action

        self._window_size = int(window_size)

        self.cfg = SimpleNamespace(
            task_suite_name="libero",
            model_family="openvla",
            pretrained_checkpoint=str(checkpoint),
            load_in_8bit=False,
            load_in_4bit=False,
            center_crop=True,
            unnorm_key=unnorm_key,
            seed=7,
        )

        set_seed_everywhere(self.cfg.seed)

        self.model = get_model(self.cfg)
        self.processor = get_processor(self.cfg)

        self.resize_size = get_image_resize_size(self.cfg)

        if self.cfg.unnorm_key not in self.model.norm_stats:
            no_noops = (
                f"{self.cfg.unnorm_key}_no_noops"
            )

            if no_noops in self.model.norm_stats:
                self.cfg.unnorm_key = no_noops
            else:
                raise RuntimeError(
                    "missing action normalization stats for "
                    f"{self.cfg.unnorm_key}"
                )

        # Load decoder state once.
        decoder_state = torch.load(
            action_decoder_path,
            map_location="cpu",
        )

        self._decoder_state = decoder_state

        # Per-session state. The official evaluator resets both
        # ActionDecoder and latent-action history at episode start.
        self._decoders: dict[str, Any] = {}
        self._history: dict[str, list[str]] = {}

    def _new_decoder(self):
        torch = self._torch
        MAPBlock = self._MAPBlock
        window_size = self._window_size

        class ActionDecoderHead(torch.nn.Module):
            def __init__(self):
                super().__init__()

                self.latent_action_pool = MAPBlock(
                    n_latents=1,
                    vis_dim=4096,
                    embed_dim=512,
                    n_heads=8,
                )

                self.visual_pool = MAPBlock(
                    n_latents=1,
                    vis_dim=4096,
                    embed_dim=512,
                    n_heads=8,
                )

                self.proj = torch.nn.Sequential(
                    torch.nn.Linear(
                        512,
                        7 * window_size,
                    ),
                    torch.nn.Tanh(),
                )

            def forward(
                self,
                latent_action_tokens,
                visual_embed,
            ):
                latent_action_tokens = (
                    latent_action_tokens[:, -4:]
                )

                visual_embed = self.visual_pool(
                    visual_embed
                )

                pooled = self.latent_action_pool(
                    latent_action_tokens,
                    init_embed=visual_embed,
                )

                return self.proj(pooled)

        class ActionDecoder(torch.nn.Module):
            def __init__(self):
                super().__init__()

                self.net = ActionDecoderHead()
                self.temporal_size = window_size

                self.temporal_mask = (
                    torch.flip(
                        torch.triu(
                            torch.ones(
                                self.temporal_size,
                                self.temporal_size,
                                dtype=torch.bool,
                            )
                        ),
                        dims=[1],
                    )
                    .cpu()
                    .numpy()
                )

                self.temporal_weights = np.array(
                    [
                        np.exp(-0.1 * i)
                        for i in range(
                            self.temporal_size
                        )
                    ]
                )[:, None]

                self.reset()

            def reset(self):
                self.action_buffer = np.zeros(
                    (
                        self.temporal_size,
                        self.temporal_size,
                        7,
                    ),
                    dtype=np.float32,
                )

                self.action_buffer_mask = np.zeros(
                    (
                        self.temporal_size,
                        self.temporal_size,
                    ),
                    dtype=np.bool_,
                )

            def forward(
                self,
                latent_actions,
                visual_embed,
                mask,
                action_low,
                action_high,
            ):
                pred = self.net(
                    latent_actions.to(torch.float),
                    visual_embed.to(torch.float),
                ).reshape(
                    -1,
                    self.temporal_size,
                    7,
                )

                pred = (
                    pred.detach()
                    .cpu()
                    .numpy()
                    .astype(np.float32)
                )

                self.action_buffer[1:] = (
                    self.action_buffer[:-1]
                )

                self.action_buffer_mask[1:] = (
                    self.action_buffer_mask[:-1]
                )

                self.action_buffer[:, :-1] = (
                    self.action_buffer[:, 1:]
                )

                self.action_buffer_mask[:, :-1] = (
                    self.action_buffer_mask[:, 1:]
                )

                self.action_buffer_mask = (
                    self.action_buffer_mask
                    * self.temporal_mask
                )

                self.action_buffer[0] = pred[0]

                self.action_buffer_mask[0] = True

                weights = (
                    self.action_buffer_mask[:, 0:1]
                    * self.temporal_weights
                )

                denom = np.sum(weights)

                if denom <= 0:
                    raise RuntimeError(
                        "empty UniVLA temporal aggregation buffer"
                    )

                action = np.sum(
                    self.action_buffer[:, 0, :]
                    * weights,
                    axis=0,
                ) / denom

                action = np.where(
                    mask,
                    0.5
                    * (action + 1)
                    * (action_high - action_low)
                    + action_low,
                    action,
                )

                return action.astype(np.float32)

        decoder = ActionDecoder()

        decoder.net.load_state_dict(
            self._decoder_state
        )

        decoder.eval().cuda()

        return decoder

    async def on_episode_start(
        self,
        config: dict[str, Any],
        ctx: SessionContext,
    ) -> None:
        await super().on_episode_start(
            config,
            ctx,
        )

        self._decoders[ctx.session_id] = (
            self._new_decoder()
        )

        # Exact official initial history.
        self._history[ctx.session_id] = [""]

    async def on_episode_end(
        self,
        result: dict[str, Any],
        ctx: SessionContext,
    ) -> None:
        self._decoders.pop(
            ctx.session_id,
            None,
        )

        self._history.pop(
            ctx.session_id,
            None,
        )

        await super().on_episode_end(
            result,
            ctx,
        )

    def get_observation_params(
        self,
    ) -> dict[str, Any]:
        return {
            "send_wrist_image": False,
            "send_state": False,
        }

    def get_action_spec(
        self,
    ) -> dict[str, DimSpec]:
        return {
            "position": POSITION_DELTA,
            "rotation": ROTATION_AA,
            "gripper": GRIPPER_CLOSE_POS,
        }

    def get_observation_spec(
        self,
    ) -> dict[str, DimSpec]:
        return {
            "agentview": IMAGE_RGB,
            "language": LANGUAGE,
        }

    def predict(
        self,
        obs: Observation,
        ctx: SessionContext,
    ) -> Action:
        images = obs.get("images", {})

        if "agentview" not in images:
            raise KeyError(
                "missing agentview image"
            )

        sid = ctx.session_id

        decoder = self._decoders.get(sid)
        history = self._history.get(sid)

        if decoder is None or history is None:
            raise RuntimeError(
                "UniVLA episode state not initialized"
            )

        # Official LIBERO helper ultimately constructs the
        # full_image input expected by get_latent_action().
        image = np.asarray(
            images["agentview"]
        )

        upstream_obs = {
            "full_image": image,
        }

        task = str(
            obs.get(
                "task_description",
                "",
            )
        )

        latent_action, visual_embed, generated_ids = (
            self._get_latent_action(
                self.cfg,
                self.model,
                upstream_obs,
                task,
                processor=self.processor,
                hist_action=history[-1],
            )
        )

        tokens = []

        for token_id in generated_ids[0]:
            idx = (
                int(token_id.item())
                - self.LATENT_ACTION_BASE_ID
            )

            if not (
                0
                <= idx
                < self.LATENT_ACTION_VOCAB_SIZE
            ):
                raise ValueError(
                    f"unexpected latent action token "
                    f"id={int(token_id.item())}"
                )

            tokens.append(
                f"<ACT_{idx}>"
            )

        history.append(
            "".join(tokens)
        )

        # Official implementation retains at most the
        # recent latent-action context semantically; only
        # history[-1] is supplied to the next call.
        if len(history) > 5:
            del history[:-5]

        stats = self.model.get_action_stats(
            self.cfg.unnorm_key
        )

        mask = stats.get(
            "mask",
            np.ones_like(
                stats["q01"],
                dtype=bool,
            ),
        )

        action_high = np.asarray(
            stats["q99"],
            dtype=np.float32,
        )

        action_low = np.asarray(
            stats["q01"],
            dtype=np.float32,
        )

        action = decoder(
            latent_action,
            visual_embed,
            mask,
            action_low,
            action_high,
        )

        action = np.asarray(
            action,
            dtype=np.float32,
        )

        if action.shape != (7,):
            raise ValueError(
                f"expected single 7-D action, "
                f"got {action.shape}"
            )

        action = self._normalize_gripper_action(
            action,
            binarize=True,
        )

        action = self._invert_gripper_action(
            action
        )

        if not np.isfinite(action).all():
            raise ValueError("non-finite UniVLA action")

        # 1-D output intentionally bypasses harness chunk buffer.
        return {
            "actions": action,
        }


if __name__ == "__main__":
    from vla_eval.model_servers.serve import (
        run_server,
    )

    run_server(
        UniVLAOpenDriveLabModelServer
    )
