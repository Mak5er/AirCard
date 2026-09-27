import sys
from pathlib import Path
import atexit
import tempfile
import zipfile
import unittest

_fixture = tempfile.TemporaryDirectory(prefix="aircard-test-theme-")
atexit.register(_fixture.cleanup)
SAMPLE_THEME = str(Path(_fixture.name) / "sample.passthm")
with zipfile.ZipFile(SAMPLE_THEME, "w") as archive:
    for digit in range(10):
        archive.writestr(f"TelephonyUI-10/ru-{digit}---white.png", b"test-image")


# Add project root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from aircard_backend import parse_passthm_archive, KEYPAD_SUBTEXTS


def verify_archive_extraction(passthm_path: str, name: str):
    if not Path(passthm_path).is_file():
        raise unittest.SkipTest("External reference theme is not available")
    telephony_ver = "TelephonyUI-10"
    items = parse_passthm_archive(passthm_path, telephony_ver)
    
    assert len(items) > 0, f"No items returned for {name}"
    
    leaves = [item[1] for item in items]
    target_dirs = [item[0] for item in items]
    
    # Check deduplication
    assert len(leaves) == len(set(leaves)), f"Duplicate filenames found in output for {name}"
    
    # Target directory verification
    expected_dir = f"/var/mobile/Library/Caches/{telephony_ver}"
    for tdir in target_dirs:
        assert tdir == expected_dir, f"Unexpected target directory: {tdir}"
        
    for d in range(10):
        digit = str(d)
        
        # Must have blank subtext variants for en-, other-, ru-, uk- and bold
        for lang in ["en", "other", "ru", "uk"]:
            for bold in ["", "-bold"]:
                blank_fn = f"{lang}-{digit}---white{bold}.png"
                assert blank_fn in leaves, f"Missing {blank_fn} for digit {digit} in {name}"
        
        # Must have standard subtext variants if subtext is defined
        subtext = KEYPAD_SUBTEXTS.get(digit, "")
        if subtext:
            for lang in ["en", "other", "ru", "uk"]:
                for bold in ["", "-bold"]:
                    sub_fn = f"{lang}-{digit}-{subtext}--white{bold}.png"
                    assert sub_fn in leaves, f"Missing {sub_fn} for digit {digit} in {name}"

    print(f"✓ {name} parsed all 10 digits with en-, other-, ru-, uk-, bold and subtext variants successfully")


def test_synthetic_multilingual_theme():
    minepass_path = SAMPLE_THEME
    verify_archive_extraction(minepass_path, "synthetic multilingual theme")


def test_tck():
    tck_path = "/Users/mak5er/Downloads/AyuGram Desktop/тцк.passthm"
    verify_archive_extraction(tck_path, "тцк.passthm")


def test_filtered_modes():
    minepass_path = SAMPLE_THEME
    # Test uk + bold only
    items_uk_bold = parse_passthm_archive(minepass_path, "TelephonyUI-10", target_lang="uk", target_bold="bold")
    leaves_uk_bold = [item[1] for item in items_uk_bold]
    assert all("bold" in leaf for leaf in leaves_uk_bold), "Non-bold files present in bold-only mode"
    assert any("uk-6" in leaf for leaf in leaves_uk_bold), "Missing uk-6 key in uk mode"
    assert not any("ru-" in leaf for leaf in leaves_uk_bold), "ru- files present when uk selected"
    print(f"✓ Fast mode (uk + bold) generated {len(items_uk_bold)} targeted assets (instead of 600+)")
    
    # Test en + regular only
    items_en_reg = parse_passthm_archive(minepass_path, "TelephonyUI-10", target_lang="en", target_bold="regular")
    leaves_en_reg = [item[1] for item in items_en_reg]
    assert not any("bold" in leaf for leaf in leaves_en_reg), "Bold files present in regular-only mode"
    print(f"✓ Fast mode (en + regular) generated {len(items_en_reg)} targeted assets")


def test_digit_5_and_universal():
    minepass_path = SAMPLE_THEME
    # Test digit 5 in ru + bold
    items_ru_bold = parse_passthm_archive(minepass_path, "TelephonyUI-9", target_lang="ru", target_bold="bold")
    leaves = [item[1] for item in items_ru_bold]
    
    # Must have ru-5-J K L--white-bold.png (the exact filename from user screenshot!)
    assert "ru-5-J K L--white-bold.png" in leaves, "Missing ru-5-J K L--white-bold.png"
    assert "ru-5---white-bold.png" in leaves, "Missing ru-5---white-bold.png"
    assert "ru-5-JKL--white-bold.png" in leaves, "Missing ru-5-JKL--white-bold.png"
    assert "ru-5-М Н О П--white-bold.png" in leaves, "Missing ru-5-М Н О П--white-bold.png"
    
    # Ensure target directory matches TelephonyUI-9
    assert all(item[0] == "/var/mobile/Library/Caches/TelephonyUI-9" for item in items_ru_bold)
    print("✓ Digit 5 verified for ru + bold with Latin, unspaced, Cyrillic, and blank subtext variants")
    
    # Test universal folder mode
    items_universal = parse_passthm_archive(minepass_path, "all", target_lang="ru", target_bold="bold")
    dirs = set(item[0] for item in items_universal)
    assert "/var/mobile/Library/Caches/TelephonyUI-10" in dirs
    assert "/var/mobile/Library/Caches/TelephonyUI-9" in dirs
    assert "/var/mobile/Library/Caches/TelephonyUI-8" in dirs
    print("✓ Universal directory mode covers TelephonyUI-8, 9, and 10")


def test_build_archive_multi():
    import io
    import zipfile
    from apply_card_skin import build_archive_multi

    target = "/var/mobile/Library/Caches/TelephonyUI-10"
    files = [
        ("en-0---white.png", b"DATA_0"),
        ("en-1---white.png", b"DATA_1"),
        ("en-2---white.png", b"DATA_2"),
    ]
    raw_zip = build_archive_multi(target, files)
    assert len(raw_zip) > 0, "build_archive_multi returned empty data"

    with zipfile.ZipFile(io.BytesIO(raw_zip), "r") as z:
        names = z.namelist()
        assert "META-INF/com.apple.ZipMetadata.plist" in names
        assert "p0/p1/p2/link" in names
        assert "payload_0" in names
        assert "payload_1" in names
        assert "payload_2" in names
        assert "payload" in names
        assert z.read("payload_0") == b"DATA_0"
        assert z.read("payload_1") == b"DATA_1"
        assert z.read("payload_2") == b"DATA_2"
        assert z.read("payload") == b"DATA_0"

        # Check symlink destination
        link_info = z.getinfo("p0/p1/p2/link")
        assert (link_info.external_attr >> 16) & 0o170000 == 0o120000
        assert z.read("p0/p1/p2/link") == b"../../../var/mobile/Library/Caches/TelephonyUI-10"

    print("✓ build_archive_multi verified (metadata, link, payloads, compatibility fallback)")


def test_cmd_flash_passthm_batch_fast():
    import io
    import json
    from contextlib import redirect_stdout
    from unittest.mock import Mock, patch
    import aircard_backend

    minepass_path = SAMPLE_THEME
    mock_batch = Mock(return_value=True)
    mock_single = Mock(return_value=True)

    buf = io.StringIO()
    with (
        patch.object(aircard_backend, "write_files_batch", mock_batch),
        patch.object(aircard_backend, "write_file", mock_single),
        redirect_stdout(buf),
    ):
        ok = aircard_backend.cmd_flash_passthm(
            "dummy_udid",
            minepass_path,
            telephony_ver="TelephonyUI-10",
            target_lang="en",
            target_bold="regular",
        )

    assert ok is True, "cmd_flash_passthm returned False"
    # Should only call write_files_batch ONCE for TelephonyUI-10
    assert mock_batch.call_count == 1, f"Expected 1 batch call, got {mock_batch.call_count}"
    # write_file (single) should NOT have been called because batch succeeded
    assert mock_single.call_count == 0, f"Expected 0 single calls, got {mock_single.call_count}"

    # Verify arguments passed to write_files_batch
    call_args = mock_batch.call_args
    assert call_args[0][0] == "dummy_udid"
    assert call_args[0][1] == "/var/mobile/Library/Caches/TelephonyUI-10"
    batched_files = call_args[0][2]
    assert len(batched_files) > 50, f"Expected >50 files batched, got {len(batched_files)}"

    # Check progress output
    output_lines = [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]
    assert any(line.get("type") == "progress" for line in output_lines)
    assert any(line.get("type") == "success" for line in output_lines)
    print(f"✓ cmd_flash_passthm fast batch verified (1 batch call for {len(batched_files)} files, 0 slow individual writes)")


def test_cmd_flash_passthm_fallback():
    import io
    import json
    from contextlib import redirect_stdout
    from unittest.mock import Mock, patch
    import aircard_backend

    minepass_path = SAMPLE_THEME
    mock_batch = Mock(return_value=False)  # Batch fails!
    mock_single = Mock(return_value=True)  # Fallback succeeds

    buf = io.StringIO()
    with (
        patch.object(aircard_backend, "write_files_batch", mock_batch),
        patch.object(aircard_backend, "write_file", mock_single),
        redirect_stdout(buf),
    ):
        ok = aircard_backend.cmd_flash_passthm(
            "dummy_udid",
            minepass_path,
            telephony_ver="TelephonyUI-10",
            target_lang="uk",
            target_bold="bold",
        )

    assert ok is True, "cmd_flash_passthm fallback returned False"
    assert mock_batch.call_count == 1, "Batch should have been attempted"
    assert mock_single.call_count > 50, f"Fallback should have written all files individually, got {mock_single.call_count}"

    output_lines = [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]
    assert any(line.get("type") == "warning" and "批量寫入失敗" in line.get("message", "") for line in output_lines)
    assert any(line.get("type") == "success" for line in output_lines)
    print(f"✓ cmd_flash_passthm fallback verified ({mock_single.call_count} individual writes after batch failure)")


if __name__ == "__main__":
    test_synthetic_multilingual_theme()
    test_tck()
    test_filtered_modes()
    test_digit_5_and_universal()
    test_build_archive_multi()
    test_cmd_flash_passthm_batch_fast()
    test_cmd_flash_passthm_fallback()
    print("All backend passthm & fast batch flasher tests passed successfully! ✅")


def load_tests(loader, tests, pattern):
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            tests.addTest(unittest.FunctionTestCase(function))
    return tests
