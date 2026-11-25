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


# ── Graphics ────────────────────────────────────────────────────────────────

import pytest  # noqa: E402

PIL = pytest.importorskip("PIL")


RACING = {"phase": "running", "title": "Stock Rock Crawlers Q2", "nowMs": 0,
          "timeUpAtMs": 185000, "standings": [{"racerName": "Riley Schuit", "laps": 7}]}


@pytest.mark.parametrize("st", [
    healthy(),
    healthy(race=RACING),
    healthy(sdr_present=False, decoder={"online": False}, wired_ip=None),
    healthy(decoder={"online": True, "noise": -24.0}),
    healthy(app_ok=False, portal_active=False, sdr_present=False, decoder_active=False,
            wifi_up=False, host="a-very-long-hostname-that-will-not-fit-the-header"),
])
def test_draw_screen_is_lcd_sized(st):
    img = ls.draw_screen(st, now=0)
    assert img.size == (480, 320)
    assert img.mode == "RGB"


def test_problems_panel_is_red_and_ok_panel_green():
    ok = ls.draw_screen(healthy(), now=0).getpixel((240, 300))
    bad = ls.draw_screen(healthy(sdr_present=False), now=0).getpixel((240, 300))
    assert ok[1] > ok[0]
    assert bad[0] > bad[1]


def test_rgb565_little_endian():
    from PIL import Image
    px = [ls.to_rgb565(Image.new("RGB", (1, 1), c)).hex()
          for c in ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255))]
    assert px == ["00f8", "e007", "1f00", "ffff"]


def _fake_fb(tmp_path, monkeypatch, size="480,320", bpp="16", stride="960"):
    info = tmp_path / "sys/class/graphics/fb0"
    info.mkdir(parents=True)
    (info / "virtual_size").write_text(size)
    (info / "bits_per_pixel").write_text(bpp)
    (info / "stride").write_text(stride)
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    monkeypatch.setattr(ls, "SYS", tmp_path / "sys")
    return dev


def test_framebuffer_writes_whole_frame_once(tmp_path, monkeypatch):
    dev = _fake_fb(tmp_path, monkeypatch)
    fb = ls.Framebuffer(str(dev))
    img = ls.draw_screen(healthy(), now=0)
    fb.show(img)
    assert dev.stat().st_size == 480 * 320 * 2
    dev.write_bytes(b"")
    fb.show(img)  # unchanged frame: nothing written
    assert dev.stat().st_size == 0


def test_framebuffer_scales_and_pads_32bpp(tmp_path, monkeypatch):
    dev = _fake_fb(tmp_path, monkeypatch, size="800,480", bpp="32", stride="3328")
    ls.Framebuffer(str(dev)).show(ls.draw_screen(healthy(), now=0))
    assert dev.stat().st_size == 3328 * 480


def test_text_mode_forced(monkeypatch):
    monkeypatch.setenv("STATUS_MODE", "text")
    assert ls.open_framebuffer() is None


def _fbs(tmp_path, monkeypatch, **names):
    for dev, name in names.items():
        info = tmp_path / "sys/class/graphics" / dev
        info.mkdir(parents=True)
        (info / "name").write_text(name)
    monkeypatch.setattr(ls, "SYS", tmp_path / "sys")
    monkeypatch.setattr(ls, "FB_DEV", "")


def test_find_framebuffer_prefers_spi_lcd(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb", fb1="fb_ili9486")
    assert ls.find_framebuffer() == "/dev/fb1"


def test_find_framebuffer_hdmi_only(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb")
    assert ls.find_framebuffer() == "/dev/fb0"


def test_find_framebuffer_none(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch)
    assert ls.find_framebuffer() is None


def test_find_framebuffer_waits_for_lcd(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb")
    slept = []

    def appear(_):
        slept.append(1)
        info = tmp_path / "sys/class/graphics/fb1"
        info.mkdir(parents=True, exist_ok=True)
        (info / "name").write_text("fb_ili9486")

    assert ls.find_framebuffer(wait_s=30, sleep=appear) == "/dev/fb1"
    assert slept == [1]


def test_find_framebuffer_env_override(monkeypatch):
    monkeypatch.setattr(ls, "FB_DEV", "/dev/fb7")
    assert ls.find_framebuffer() == "/dev/fb7"


# ── Both screens: LCD dashboard + HDMI race view ────────────────────────────

def test_find_screens_lcd_and_hdmi(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb", fb1="fb_ili9486")
    assert ls.find_screens() == [("/dev/fb0", "hdmi"), ("/dev/fb1", "lcd")]


def test_find_screens_waits_for_lcd(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb")

    def appear(_):
        info = tmp_path / "sys/class/graphics/fb1"
        info.mkdir(parents=True, exist_ok=True)
        (info / "name").write_text("fb_ili9486")

    assert [k for _, k in ls.find_screens(wait_s=30, sleep=appear)] == ["hdmi", "lcd"]


def test_find_screens_env_override(tmp_path, monkeypatch):
    _fbs(tmp_path, monkeypatch, fb0="vc4drmfb", fb1="fb_ili9486")
    monkeypatch.setattr(ls, "FB_DEV", "/dev/fb1")
    assert ls.find_screens() == [("/dev/fb1", "lcd")]


TWELVE = {"phase": "running", "title": "2WD Buggy A-Main", "nowMs": 0, "timeUpAtMs": 300000,
          "standings": [{"racerName": f"Racer {i}", "place": i, "laps": 20 - i,
                         "totalMs": 300000 + i * 900, "lastLapMs": 15000 + i * 10,
                         "bestLapMs": 14500 + i * 10} for i in range(1, 14)]}


@pytest.mark.parametrize("size", [(1280, 720), (1920, 1080), (1024, 768)])
@pytest.mark.parametrize("st", [
    healthy(),
    healthy(race=TWELVE),
    healthy(race={"phase": "countdown", "title": "Q1", "nowMs": 0, "goAtMs": 15000,
                  "standings": [{"racerName": "A", "grid": 1}]}),
    healthy(sdr_present=False, wired_ip=None, decoder={"online": False}),
])
def test_draw_hdmi_any_size(st, size):
    assert ls.draw_hdmi(st, *size, now=0).size == size


def test_status_strip_flags_problems():
    ok = ls.status_strip(healthy())
    assert ok[-1] == ("All OK", ls.OKC)
    bad = ls.status_strip(healthy(sdr_present=False))
    assert bad[-1][1] == ls.BAD and "SDR not plugged in" in bad[-1][0]


def test_laptime_formats():
    assert ls._laptime(14523) == "14.523"
    assert ls._laptime(75250) == "1:15.250"
    assert ls._laptime(None) == "–"
    assert ls._total(305400) == "5:05.4"
