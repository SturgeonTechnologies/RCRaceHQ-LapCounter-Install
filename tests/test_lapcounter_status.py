"""Tests for files/lapcounter-status (render + problem detection, no hardware)."""

import importlib.machinery
import importlib.util
import pathlib
import sys

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "files" / "lapcounter-status"


def _load():
    loader = importlib.machinery.SourceFileLoader("lapcounter_status", str(SCRIPT))
    spec = importlib.util.spec_from_loader("lapcounter_status", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["lapcounter_status"] = module
    loader.exec_module(module)
    return module


ls = _load()


def healthy(**kw):
    base = dict(host="race-pi", wired_ip="192.168.1.20", wired_link=True, internet=True,
                wifi_on=True, wifi_up=True, ssid="RC Race Event", wifi_clients=3,
                sdr_present=True, decoder_active=True, portal_active=True, app_ok=True,
                decoder={"online": True, "noise": -41.2})
    base.update(kw)
    return ls.State(**base)


def text(st):
    return "\n".join(ls.render(st, 60))


def test_all_ok_shows_ip_ssid_and_noise():
    out = text(healthy())
    assert "Wired  192.168.1.20  (internet)" in out
    assert "Wi-Fi  RC Race Event" in out
    assert "3 joined" in out
    assert "Race   none yet" in out
    assert "All OK  noise -41 dBFS" in out
    assert "PROBLEMS" not in out


def test_offline_wired():
    out = text(healthy(wired_ip=None, wired_link=False, internet=False))
    assert "Wired  OFFLINE (no cable)" in out
    out = text(healthy(wired_ip=None, wired_link=True))
    assert "cable in, no address" in out


def test_sdr_unplugged_is_a_problem():
    st = healthy(sdr_present=False, decoder={"online": False})
    assert ls.problems(st)[0] == "SDR not plugged in (USB)"
    # Not also reported as "decoder silent": the SDR is the cause.
    assert not any("silent" in p for p in ls.problems(st))


def test_decoder_stopped_and_silent():
    assert "Decoder stopped" in ls.problems(healthy(decoder_active=False))
    assert any("silent" in p for p in ls.problems(healthy(decoder={"online": False})))


def test_noisy_rf():
    assert any(p.startswith("Noisy RF: -20") for p in ls.problems(healthy(decoder={"online": True, "noise": -20.0})))
    assert not ls.problems(healthy(decoder={"online": True, "noise": -38.0}))


def test_app_and_portal_down():
    found = ls.problems(healthy(app_ok=False, portal_active=False, decoder={}))
    assert "App not answering" in found
    assert "Web portal (port 80) stopped" in found


def test_wifi_off_and_down():
    assert "event Wi-Fi off" in text(healthy(wifi_on=False))
    st = healthy(wifi_up=False)
    assert "DOWN" in text(st)
    assert "Event Wi-Fi is down" in ls.problems(st)


def test_running_race():
    race = {"phase": "running", "title": "Stock Rock Crawlers A-Main", "nowMs": 10_000,
            "timeUpAtMs": 100_000, "standings": [{"racerName": "Riley", "laps": 4}]}
    out = text(healthy(race=race))
    assert "Race   RACING" in out
    assert "Stock Rock Crawlers A-Main" in out
    assert "1:30 left" in out
    assert "1st Riley (4 laps)" in out


def test_countdown():
    race = {"phase": "countdown", "title": "Q1", "nowMs": 0, "goAtMs": 12_000, "standings": []}
    assert "starts in 0:12" in text(healthy(race=race))


def test_lines_fit_width():
    st = healthy(ssid="x" * 80, race={"phase": "finished", "title": "y" * 80, "nowMs": 0})
    assert all(len(line) <= 30 for line in ls.render(st, 30))


def test_lease_count(tmp_path):
    f = tmp_path / "leases"
    f.write_text("0 aa:bb 10.77.0.50 phone *\n9999999999 cc:dd 10.77.0.51 tab *\n1 ee:ff 10.77.0.52 old *\n")
    assert ls.lease_count(str(f)) == 2


def test_paint_marks_problems_red():
    out = ls.paint([" ! SDR not plugged in (USB)", "All OK"])
    assert ls.RED in out and ls.GREEN in out
