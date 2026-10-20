import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import merge_authorized_keys as mak  # noqa: E402

A = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIaaaa laptop"
B = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIbbbb desktop"
C = "ssh-rsa AAAAB3NzaC1yc2EAAAAcccc other"


def test_existing_lines_preserved_in_order():
    existing = f"# note\n{C}\n\n{A}\n"
    out = mak.merge(existing, [B])
    assert out.splitlines()[:4] == ["# note", C, "", A]
    assert out.splitlines()[4] == B


def test_missing_key_appended():
    assert mak.merge(f"{A}\n", [B]) == f"{A}\n{B}\n"


def test_same_key_different_comment_not_duplicated():
    out = mak.merge(f"{A}\n", ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIaaaa renamed"])
    assert out == f"{A}\n"


def test_options_prefix_still_matches():
    existing = f'command="x" {A}\n'
    assert mak.merge(existing, [A]) == existing


def test_idempotent():
    x = f"{C}\n{A}\n"
    w = [A, B]
    assert mak.merge(mak.merge(x, w), w) == mak.merge(x, w)


def test_input_without_trailing_newline():
    assert mak.merge(A, [B]) == f"{A}\n{B}\n"
    assert mak.merge(A, [A]) == f"{A}\n"


def test_empty_existing():
    assert mak.merge("", [A, B]) == f"{A}\n{B}\n"
    assert mak.merge("", []) == ""
