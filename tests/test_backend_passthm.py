import sys
import base64
import tempfile
import unittest
import zipfile
from contextlib import contextmanager
from pathlib import Path

# Add project root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from aircard_backend import parse_passthm_archive, KEYPAD_SUBTEXTS


def verify_archive_extraction(passthm_path: str, name: str):
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


def test_standard_theme_layout():
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=False) as minepass_path:
        verify_archive_extraction(minepass_path, "标准测试主题.passthm")


def test_nested_unicode_theme_layout():
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=True) as tck_path:
        verify_archive_extraction(tck_path, "中文嵌套主题.passthm")


def test_filtered_modes():
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=False) as minepass_path:
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
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=False) as minepass_path:
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
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=False) as minepass_path:
        import io
        import json
        from contextlib import redirect_stdout
        from unittest.mock import Mock, patch
        import aircard_backend

        mock_batch = Mock(return_value=True)
        mock_single = Mock(return_value=True)

        buf = io.StringIO()
        with (
            patch.object(aircard_backend, "write_files_batch", mock_batch),
            patch.object(aircard_backend, "write_file", mock_single),
            patch.object(aircard_backend.time, "sleep"),
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
    # 准备临时主题，验证解析和写入时不再依赖个人电脑上的下载文件。
    with generated_theme(nested=False) as minepass_path:
        import io
        import json
        from contextlib import redirect_stdout
        from unittest.mock import Mock, patch
        import aircard_backend

        mock_batch = Mock(return_value=False)  # Batch fails!
        mock_single = Mock(return_value=True)  # Fallback succeeds

        buf = io.StringIO()
        with (
            patch.object(aircard_backend, "write_files_batch", mock_batch),
            patch.object(aircard_backend, "write_file", mock_single),
            patch.object(aircard_backend.time, "sleep"),
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
        assert any(line.get("type") == "warning" and "批量写入未完成" in line.get("message", "") for line in output_lines)
        assert any(line.get("type") == "success" for line in output_lines)
        print(f"✓ cmd_flash_passthm fallback verified ({mock_single.call_count} individual writes after batch failure)")


@contextmanager
def generated_theme(nested=False):
    # 每次生成含十个数字按键的有效 PNG 主题，确保中文路径和临时文件清理都受到覆盖。
    png = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    with tempfile.TemporaryDirectory(prefix="aircard-theme-") as directory:
        path = Path(directory) / "中文测试主题.passthm"
        prefix = "中文目录/TelephonyUI-10/" if nested else "TelephonyUI-10/"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(prefix + "_big", b"")
            for digit in range(10):
                archive.writestr(prefix + f"en-{digit}---white.png", png)
        yield str(path)


def load_tests(loader, tests, pattern):
    # 将原来的函数式回归用例接入项目已有的 unittest 入口，避免常规测试命令漏跑主题测试。
    return unittest.TestSuite(
        unittest.FunctionTestCase(test)
        for name, test in sorted(globals().items())
        if name.startswith("test_") and callable(test)
    )


if __name__ == "__main__":
    test_standard_theme_layout()
    test_nested_unicode_theme_layout()
    test_filtered_modes()
    test_digit_5_and_universal()
    test_build_archive_multi()
    test_cmd_flash_passthm_batch_fast()
    test_cmd_flash_passthm_fallback()
    print("All backend passthm & fast batch flasher tests passed successfully! ✅")
