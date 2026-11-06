import base64
import os

import pytest

from jarvis import chrome
from jarvis.goal_runner import SubGoal
from jarvis.tools import (
    choose_candidate,
    choose_file_input,
    drag_outcome,
    humanize_dates,
    resolve_upload_path,
    safe_name,
    save_file,
    search_url,
    unique_path,
    upload_roots,
    verify_requirements,
)


def test_search_urls_for_each_engine_and_kind():
    assert search_url("palm trees", "images") == "https://www.google.com/search?q=palm+trees&hl=en&tbm=isch"
    assert search_url("a b", "web", "duckduckgo") == "https://duckduckgo.com/?q=a+b"
    assert search_url("tour eiffel", "maps").startswith("https://www.google.com/maps/search/tour%20eiffel")
    assert "bing.com/images/search" in search_url("x", "images", "bing")


def test_iso_dates_become_the_form_a_calendar_shows():
    assert humanize_dates("depart 2026-11-20, return 2026-12-04") == "depart November 20, 2026, return December 4, 2026"
    assert humanize_dates("1 adult") == "1 adult"


def test_requirements_are_verified_against_the_final_page_not_the_models_word():
    page = {"title": "London to Madrid", "url": "https://x.test/?d=2026-11-20", "text": "Fri, Nov 20\nNonstop\n1 passenger",
            "actions": [{"label": "Where from?", "value": "London"}, {"label": "Where to?", "value": "Madrid"}]}
    goal = SubGoal("g", [{"what": "from", "value": "London"}, {"what": "to", "value": "Madrid"}, {"what": "date", "value": "November 20, 2026"},
                         {"what": "pax", "value": "1 adult"}, {"what": "stops", "value": "Nonstop only"}, {"what": "cabin", "value": "Business"}])
    assert verify_requirements(goal, page) == ["cabin = Business"]


async def test_downloads_decode_data_urls_and_never_overwrite(tmp_path):
    url = "data:image/png;base64," + base64.b64encode(b"\x89PNG-bytes").decode()
    first, size = await save_file(url, tmp_path, "Palm photo #1", None)
    second, _ = await save_file(url, tmp_path, "Palm photo #1", None)
    assert first.name == "Palm_photo_1.png" and size == 10 and first.read_bytes() == b"\x89PNG-bytes" and second != first
    assert safe_name("../../etc/passwd") == "etcpasswd" and unique_path(tmp_path, "Palm_photo_1.png").name != "Palm_photo_1.png"


def test_chrome_bundle_validation(tmp_path):
    found = chrome.find_chrome()
    if found:
        assert found.binary.exists() and found.bundle_id.startswith("com.google.Chrome")
    with pytest.raises(chrome.ChromeError):
        chrome.inspect_app(tmp_path / "Nothing.app")
    fake = tmp_path / "Other.app" / "Contents"
    fake.mkdir(parents=True)
    import plistlib

    (fake / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.apple.Safari"}))
    with pytest.raises(chrome.ChromeError, match="not Google Chrome"):
        chrome.inspect_app(tmp_path / "Other.app")


def test_existing_session_probe_explains_how_to_enable_debugging(monkeypatch, tmp_path):
    monkeypatch.setattr(chrome, "chrome_processes", lambda exclude_profile=None: [123])
    monkeypatch.setattr(chrome, "read_active_port", lambda root: None)
    monkeypatch.setattr(chrome, "port_is_live", lambda port, *a, **k: False)
    monkeypatch.setattr(chrome, "remote_debugging_toggle", lambda root=chrome.DEFAULT_CHROME_ROOT: False)
    probe = chrome.probe_existing(tmp_path)
    assert probe.running and probe.debugging == "off" and probe.ws_url is None and probe.code == "remote_debugging_off"
    assert "chrome://inspect/#remote-debugging" in chrome.HOW_TO_ENABLE and "Allow" in chrome.HOW_TO_ENABLE
    assert "Jarvis" not in chrome.HOW_TO_ENABLE and "Friday" in chrome.HOW_TO_ENABLE
    monkeypatch.setattr(chrome, "chrome_processes", lambda exclude_profile=None: [])
    absent = chrome.probe_existing(tmp_path)
    assert not absent.running and absent.code == "chrome_not_running"


def test_chrome_errors_carry_a_stable_code_and_name_friday(tmp_path):
    error = chrome.ChromeError("Chrome exited immediately (code 1).", "chrome_exited")
    assert error.code == "chrome_exited" and str(error).startswith("Chrome exited")
    assert chrome.ChromeError("x").code == "chrome_not_connected" and set(chrome.ERROR_CODES) >= {"profile_in_use", "chrome_not_found", "devtools_timeout"}
    managed = chrome.ManagedChrome.__new__(chrome.ManagedChrome)
    managed.profile_dir = tmp_path
    managed.process = None
    managed._live_ws = lambda: "ws://127.0.0.1:1/devtools"  # a window holds the profile
    with pytest.raises(chrome.ChromeError) as caught:
        managed.reset_profile()
    assert caught.value.code == "profile_in_use" and "Friday" in str(caught.value) and "Jarvis" not in str(caught.value)


# Uploads -------------------------------------------------------------------------------------------------------------------


def test_uploads_only_come_from_approved_folders(tmp_path):
    downloads = tmp_path / "Downloads" / "Friday"
    approved = tmp_path / "Documents"
    elsewhere = tmp_path / "Secrets"
    for folder in (downloads / "nested", approved, elsewhere):
        folder.mkdir(parents=True)
    (downloads / "CV.pdf").write_bytes(b"pdf")
    (downloads / "nested" / "photo.JPG").write_bytes(b"jpg")
    (approved / "notes.txt").write_bytes(b"txt")
    (elsewhere / "passwords.txt").write_bytes(b"no")
    os.symlink(elsewhere / "passwords.txt", downloads / "link.txt")  # a symlink inside pointing outside is refused
    roots = upload_roots(downloads, [str(approved), " ", str(approved)])
    assert roots == [downloads.resolve(), approved.resolve()]
    assert resolve_upload_path("CV.pdf", roots) == (downloads / "CV.pdf").resolve()
    lowered = resolve_upload_path("cv.pdf", roots)  # case-insensitive name match (APFS may keep the typed spelling)
    assert lowered is not None and lowered.is_file() and lowered.name.casefold() == "cv.pdf" and lowered.parent == downloads.resolve()
    assert resolve_upload_path("photo.jpg", roots) == (downloads / "nested" / "photo.JPG").resolve()  # found in a subfolder
    assert resolve_upload_path(str(approved / "notes.txt"), roots) == (approved / "notes.txt").resolve()
    assert resolve_upload_path('"notes.txt"', roots) == (approved / "notes.txt").resolve()
    assert resolve_upload_path(str(elsewhere / "passwords.txt"), roots) is None
    assert resolve_upload_path("passwords.txt", roots) is None
    assert resolve_upload_path("link.txt", roots) is None
    assert resolve_upload_path("../Secrets/passwords.txt", roots) is None
    assert resolve_upload_path("missing.pdf", roots) is None and resolve_upload_path("", roots) is None
    assert resolve_upload_path("CV.pdf", []) is None


def test_the_file_field_is_chosen_by_words_or_uniqueness():
    resume = {"node": 1, "label": "Résumé", "context": "Upload your résumé (PDF)", "accept": ".pdf", "visible": False}
    photo = {"node": 2, "label": "Profile photo", "context": "JPG or PNG", "accept": "image/*", "visible": True}
    assert choose_file_input([resume, photo], "resume pdf") is resume
    assert choose_file_input([resume, photo], "the photo") is photo
    assert choose_file_input([resume, photo], None) is photo  # the only visible one
    assert choose_file_input([resume, photo], "attachment") is None  # nothing matches: ask, do not guess
    assert choose_file_input([resume], None) is resume and choose_file_input([], "x") is None
    twins = [{"node": 3, "label": "Attachment", "context": "", "visible": False}, {"node": 4, "label": "Attachment", "context": "", "visible": False}]
    assert choose_file_input(twins, "attachment") is twins[0]


# Drag and drop ------------------------------------------------------------------------------------------------------------


def test_drag_candidates_are_chosen_by_label_ordinal_or_clear_overlap():
    items = [{"node": 1, "label": "Buy milk"}, {"node": 2, "label": "Write report"}, {"node": 3, "label": "Call the dentist"}]
    zones = [{"node": 10, "label": "To do"}, {"node": 11, "label": "Done"}]
    assert choose_candidate("buy milk", items) is items[0]
    assert choose_candidate("the Buy milk card", items) is items[0]
    assert choose_candidate("the second item", items) is items[1] and choose_candidate("last card", items) is items[2]
    assert choose_candidate("the Done column", items + zones) is zones[1]
    assert choose_candidate("dentist", items) is items[2]
    assert choose_candidate("the card", items) is None  # no overlap with any label
    assert choose_candidate("report milk", items) is None  # a tie between different items is ambiguous
    assert choose_candidate("x", []) is None


def test_the_drop_is_verified_from_the_page_not_from_the_mouse_events():
    before = {"source_found": True, "target_found": True, "target_contains_source": False, "same_parent": True, "source_before_target": True,
              "source_index": 0, "target_index": 2, "siblings": ["Buy milk", "Write report", "Call the dentist"], "body_length": 100}
    moved = {**before, "source_before_target": False, "source_index": 2, "target_index": 1, "siblings": ["Write report", "Call the dentist", "Buy milk"]}
    assert drag_outcome(before, moved, is_zone=False) == "moved"
    into_zone = {**before, "target_contains_source": True, "same_parent": False}
    assert drag_outcome(before, into_zone, is_zone=True) == "moved"
    assert drag_outcome(before, dict(before), is_zone=False) == "unchanged"
    assert drag_outcome(before, {**before, "body_length": 140}, is_zone=True) == "changed"
    assert drag_outcome(before, {**before, "source_found": False, "siblings": ["Write report", "Call the dentist"]}, is_zone=True) == "changed"
    assert drag_outcome(None, None, is_zone=False) == "unchanged" and drag_outcome(before, None, is_zone=False) == "changed"
