from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from public_data import ReleaseError, check, csv_string, load_public, verify_inventory
from reproduce_public import reproduce


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'candidate'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('outputs', '__pycache__', '.git'))

    def tearDown(self):
        self.temp.cleanup()

    def edit_csv(self, rel, change):
        path = self.root / rel
        with path.open(newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f); fields = reader.fieldnames; rows = list(reader)
        new_fields = change(fields, rows)
        path.write_text(csv_string(rows, new_fields or fields), encoding='utf-8')

    def semantic_failure(self):
        with self.assertRaises((ReleaseError, ValueError)):
            check(self.root, integrity=False)

    def test_valid_release(self):
        stats, scores = check(self.root)
        self.assertEqual(stats['responses'], 7000)
        self.assertEqual(len(scores), 14)
        self.assertFalse(stats['full_method_analysis_reproduced'])

    def test_matrix_shape(self):
        systems, rows = load_public(self.root)
        self.assertEqual((len(rows), len(systems)), (500, 14))

    def test_hash_tampering_rejected(self):
        with (self.root / 'README.md').open('a') as f: f.write('tamper\n')
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_missing_file_rejected(self):
        (self.root / 'data/responses.csv').unlink()
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_unexpected_file_rejected(self):
        (self.root / 'do_not_publish.txt').write_text('private')
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_extra_metadata_column_rejected(self):
        def change(fields, rows):
            for row in rows: row['private_text'] = 'withheld'
            return fields + ['private_text']
        self.edit_csv('data/responses.csv', change)
        self.semantic_failure()

    def test_duplicate_item_rejected(self):
        def change(fields, rows): rows[1]['public_item_id'] = rows[0]['public_item_id']
        self.edit_csv('data/responses.csv', change); self.semantic_failure()

    def test_original_style_item_ids_rejected(self):
        def change(fields, rows): rows[0]['public_item_id'] = '0'
        self.edit_csv('data/responses.csv', change); self.semantic_failure()

    def test_missing_item_rejected(self):
        def change(fields, rows): rows.pop()
        self.edit_csv('data/responses.csv', change); self.semantic_failure()

    def test_nonbinary_response_rejected(self):
        def change(fields, rows): rows[0][fields[1]] = '2'
        self.edit_csv('data/responses.csv', change); self.semantic_failure()

    def test_missing_response_rejected(self):
        def change(fields, rows): rows[0][fields[1]] = ''
        self.edit_csv('data/responses.csv', change); self.semantic_failure()

    def test_duplicate_system_rejected(self):
        def change(fields, rows): rows[1]['system'] = rows[0]['system']
        self.edit_csv('data/systems.csv', change); self.semantic_failure()

    def test_wrong_split_rejected(self):
        def change(fields, rows): rows[0]['split'] = 'holdout'
        self.edit_csv('data/systems.csv', change); self.semantic_failure()

    def test_cross_split_family_overlap_rejected(self):
        def change(fields, rows):
            for row in rows:
                if row['split'] == 'holdout' and row['family'] == 'pi_openpi': row['family'] = rows[0]['family']
        self.edit_csv('data/systems.csv', change); self.semantic_failure()

    def test_wrong_reference_count_rejected(self):
        def change(fields, rows): rows[0]['successes'] = str(int(rows[0]['successes']) + 1)
        self.edit_csv('results/reference/full_bank_scores.csv', change); self.semantic_failure()

    def test_wrong_reference_rate_rejected(self):
        def change(fields, rows): rows[0]['success_rate'] = '0.123'
        self.edit_csv('results/reference/full_bank_scores.csv', change); self.semantic_failure()

    def test_nan_archive_rejected(self):
        def change(fields, rows): rows[0]['family_balanced_mae_pp'] = 'nan'
        self.edit_csv('results/archived/holdout_comparison.csv', change); self.semantic_failure()

    def test_infinite_archive_rejected(self):
        def change(fields, rows): rows[0]['family_balanced_mae_pp'] = 'inf'
        self.edit_csv('results/archived/holdout_comparison.csv', change); self.semantic_failure()

    def test_mismatched_archived_aggregation_rejected(self):
        def change(fields, rows): rows[0]['family_balanced_mae_pp'] = '4.0'
        self.edit_csv('results/archived/holdout_comparison.csv', change); self.semantic_failure()

    def test_wrong_archived_truth_rejected(self):
        def change(fields, rows): rows[0]['truth'] = '0.999'
        self.edit_csv('results/archived/holdout_by_system.csv', change); self.semantic_failure()

    def test_missing_archive_system_row_rejected(self):
        def change(fields, rows): rows.pop()
        self.edit_csv('results/archived/holdout_by_system.csv', change); self.semantic_failure()

    def test_symlink_file_rejected(self):
        dest=self.root / 'README.md'; target=self.root.parent / 'copied.md'
        shutil.copyfile(dest,target);dest.unlink();dest.symlink_to(target)
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_symlink_directory_rejected(self):
        (self.root / 'link').symlink_to(self.root.parent, target_is_directory=True)
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_manifest_path_escape_rejected(self):
        path=self.root / 'RELEASE_MANIFEST.json'; j=json.loads(path.read_text())
        j['files']['../escape.txt']='0'*64;path.write_text(json.dumps(j))
        with self.assertRaises(ReleaseError): verify_inventory(self.root)

    def test_outputs_not_in_release_inventory(self):
        path=self.root / 'outputs/test';path.mkdir(parents=True);(path / 'report.md').write_text('runtime')
        verify_inventory(self.root)

    def test_existing_output_rejected(self):
        out=self.root / 'outputs/existing';out.mkdir(parents=True)
        with self.assertRaises(ReleaseError): reproduce(self.root,out)

    def test_output_escape_rejected(self):
        with self.assertRaises(ReleaseError): reproduce(self.root,self.root.parent / 'escape')

    def test_fresh_output_success_and_no_source_change(self):
        before=(self.root / 'RELEASE_MANIFEST.json').read_bytes()
        out=reproduce(self.root,self.root / 'outputs/test')
        self.assertEqual((out / 'full_bank_scores.csv').read_bytes(), (self.root / 'results/reference/full_bank_scores.csv').read_bytes())
        self.assertIn('NOT recomputed', (out / 'report.md').read_text())
        record=json.loads((out / 'validation.json').read_text())
        self.assertFalse(record['full_method_analysis_reproduced'])
        self.assertFalse(record['new_control_experiment'])
        self.assertEqual(before,(self.root / 'RELEASE_MANIFEST.json').read_bytes())
        verify_inventory(self.root)


if __name__ == '__main__':
    unittest.main()
