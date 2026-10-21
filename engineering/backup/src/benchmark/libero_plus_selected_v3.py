import json
from typing import Optional

from vla_eval.benchmarks.libero_plus.benchmark import (
    LIBEROPlusBenchmark,
)


class SelectedLIBEROPlusBenchmarkV3(
    LIBEROPlusBenchmark
):
    """
    Exact frozen-manifest LIBERO-Plus selection.

    Python 3.8 compatible.

    Model-server observation parameters are explicit so that the
    vla-eval orchestrator can auto-configure benchmark interfaces.
    """

    def __init__(
        self,
        *,
        manifest_path: str,
        suite: str = "libero_spatial",
        seed: int = 7,
        num_steps_wait: int = 10,
        send_wrist_image: bool = False,
        send_state: bool = False,
        absolute_action: bool = False,
        max_steps: Optional[int] = None,
        env_seed: Optional[int] = None,
        quat_no_antipodal: bool = False,
        category: Optional[str] = None,
        difficulty_level: Optional[int] = None,
    ):

        super().__init__(
            suite=suite,
            seed=seed,
            num_steps_wait=num_steps_wait,
            send_wrist_image=send_wrist_image,
            send_state=send_state,
            absolute_action=absolute_action,
            max_steps=max_steps,
            env_seed=env_seed,
            quat_no_antipodal=quat_no_antipodal,
            category=category,
            difficulty_level=difficulty_level,
        )

        self.manifest_path = manifest_path


    def get_tasks(self):

        tasks = super().get_tasks()

        with open(self.manifest_path) as f:
            manifest = json.load(f)

        selected = {
            item["registry_name"]
            for item in manifest["items"]
            if item["suite"] == self.suite
        }

        result = [
            task
            for task in tasks
            if getattr(
                task.get("task_obj"),
                "name",
                None,
            ) in selected
        ]

        found = {
            getattr(
                task.get("task_obj"),
                "name",
                None,
            )
            for task in result
        }

        missing = selected - found

        if missing:
            raise RuntimeError(
                "{}: missing selected items: {}".format(
                    self.suite,
                    sorted(missing)[:10],
                )
            )

        if len(result) != len(selected):
            raise RuntimeError(
                "{}: expected {} selected tasks, got {}".format(
                    self.suite,
                    len(selected),
                    len(result),
                )
            )

        return result
