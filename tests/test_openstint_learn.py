"""Tests for files/openstint-learn.

Run from the repo root:
    python3 -m pytest roles/openstint_decoder/tests -q

The integration test needs pyzmq; it is skipped without it.
"""

import importlib.machinery
import importlib.util
import pathlib
import threading
import time

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "files" / "openstint-learn"


def _load():
    loader = importlib.machinery.SourceFileLoader("openstint_learn", str(SCRIPT))
    spec = importlib.util.spec_from_loader("openstint_learn", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


learn = _load()


# ── parse_message ────────────────────────────────────────────────────────

def test_parse_done():
    msg = learn.parse_message("L 228855 DONE 1000 36")
    assert msg == learn.Message(kind="L", event="DONE", transponder_id=1000, value=36.0)


def test_parse_start():
    msg = learn.parse_message("L 100090 START -32.8")
    assert msg.event == "START" and msg.value == pytest.approx(-32.8)


def test_parse_interrupted_and_reset():
    assert learn.parse_message("L 1 INTERRUPTED").event == "INTERRUPTED"
    assert learn.parse_message("L 1 RESET").event == "RESET"


def test_parse_status():
    msg = learn.parse_message("S 216339 -46.53 0.97 567 525 0.04")
    assert msg.kind == "S"
    assert msg.received == 567 and msg.processed == 525
    assert msg.value == pytest.approx(-46.53)


def test_parse_passing():
    msg = learn.parse_message("P 109613 AMB 8954097 -30.86 4096 0 10.7")
    assert msg.kind == "P" and msg.transponder_id == 8954097


@pytest.mark.parametrize("raw", ["", "L", "L x DONE", "S 1 nope", "P 1 AMB notanid", "Z 1 2 3"])
def test_parse_garbage_returns_none(raw):
    assert learn.parse_message(raw) is None


# ── decide_done ──────────────────────────────────────────────────────────

def test_done_auto_id_is_renamed():
    assert learn.decide_done(1000, 8954097) == learn.Action.RENAME


def test_done_with_label_already_matching():
    # RC4 Hybrid (real ID from its RC3 message), or re-learning a known one
    assert learn.decide_done(8954097, 8954097) == learn.Action.ALREADY_LABEL


def test_done_matched_some_other_transponder():
    assert learn.decide_done(1234567, 8954097) == learn.Action.MISMATCH


# ── validate_label ───────────────────────────────────────────────────────

@pytest.mark.parametrize("label", [0, 1000, 5000, 9999, -1])
def test_label_rejected(label):
    with pytest.raises(ValueError):
        learn.validate_label(label)


@pytest.mark.parametrize("label", [1, 999, 10000, 8954097])
def test_label_accepted(label):
    learn.validate_label(label)


# ── rename_learned ───────────────────────────────────────────────────────

def test_rename_moves_file(tmp_path):
    (tmp_path / "1000.rc4").write_text("deadbeef\n")
    target = learn.rename_learned(tmp_path, 1000, 8954097, wait_s=0.1)
    assert target == tmp_path / "8954097.rc4"
    assert target.read_text() == "deadbeef\n"
    assert not (tmp_path / "1000.rc4").exists()


def test_rename_refuses_to_overwrite(tmp_path):
    (tmp_path / "1000.rc4").write_text("new\n")
    (tmp_path / "8954097.rc4").write_text("old\n")
    with pytest.raises(FileExistsError):
        learn.rename_learned(tmp_path, 1000, 8954097, wait_s=0.1)
    assert (tmp_path / "8954097.rc4").read_text() == "old\n"


def test_rename_missing_source(tmp_path):
    with pytest.raises(FileNotFoundError):
        learn.rename_learned(tmp_path, 1000, 8954097, wait_s=0.1)


def test_stray_auto_files(tmp_path):
    for name in ("1000.rc4", "1001.rc4", "8954097.rc4", "notes.txt", "12.rc4"):
        (tmp_path / name).write_text("")
    assert learn.stray_auto_files(tmp_path) == ["1000.rc4", "1001.rc4"]


# ── end to end against a fake decoder ────────────────────────────────────

zmq = pytest.importorskip("zmq")


def _fake_decoder(port, directory, script):
    ctx = zmq.Context.instance()
    pub = ctx.socket(zmq.PUB)
    pub.bind(f"tcp://127.0.0.1:{port}")
    time.sleep(0.3)  # let the subscriber connect (pub-sub drops early messages)
    for line in script:
        if line.startswith("L") and " DONE " in line:
            auto_id = line.split()[3]
            (directory / f"{auto_id}.rc4").write_text("0011223344556677\n")
        pub.send_string(line)
        time.sleep(0.02)
    time.sleep(0.3)
    pub.close(linger=0)


def _free_port():
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_learn_end_to_end(tmp_path, capsys):
    port = _free_port()
    script = [
        "S 1 -47.0 1.0 700 620 0.03",
        "L 2 START -28.1",
        "L 3 INTERRUPTED",
        "L 4 START -27.9",
        "L 5 DONE 1000 36",
        "P 6 AMB 8954097 -30.9 40 0 10.7",
    ]
    t = threading.Thread(target=_fake_decoder, args=(port, tmp_path, script))
    t.start()
    rc = learn.main(
        ["8954097", "--port", str(port), "--dir", str(tmp_path),
         "--timeout", "5", "--verify-timeout", "3"]
    )
    t.join()
    out = capsys.readouterr().out
    assert rc == 0, out
    assert (tmp_path / "8954097.rc4").exists()
    assert "INTERRUPTED" in out
    assert "Verified" in out


def test_learn_times_out(tmp_path):
    port = _free_port()
    rc = learn.main(["8954097", "--port", str(port), "--dir", str(tmp_path), "--timeout", "0.5"])
    assert rc == learn.EXIT_TIMEOUT
