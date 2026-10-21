import json

from vla_eval.benchmarks.libero_plus.benchmark import (
    LIBEROPlusBenchmark,
)


class SelectedLIBEROPlusBenchmark(
    LIBEROPlusBenchmark
):
    """
    Restrict LIBERO-Plus to immutable registry-name items
    recorded in a research manifest.
    """

    def __init__(
        self,
        *,
        manifest_path: str,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.manifest_path = manifest_path

    def get_tasks(self):
        tasks = super().get_tasks()

        with open(
            self.manifest_path
        ) as f:
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
                f"Manifest mismatch for {self.suite}: "
                f"{len(missing)} missing items: "
                f"{sorted(missing)[:10]}"
            )

        if len(result) != len(selected):
            raise RuntimeError(
                f"Unexpected duplicate selection in {self.suite}: "
                f"result={len(result)}, selected={len(selected)}"
            )

        return result
