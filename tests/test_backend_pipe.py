"""Exercise the GUI's actual pipe reader without launching the app or a device."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'requires macOS Swift')
class BackendPipeTests(unittest.TestCase):
    def test_exit_drain_delayed_output_and_inherited_pipe(self):
        source = (pathlib.Path(__file__).resolve().parents[1] / 'AirCardApp.swift').read_text()
        reader = source.split('struct BackendPipeReader {', 1)[1].split('// Observe USB', 1)[0]
        harness = r'''
func check(_ command: String, _ expected: String, maxDuration: Double = 3) throws {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try pipe.fileHandleForWriting.close()
    let reader = try BackendPipeReader(pipe.fileHandleForReading)
    let start = Date()
    var output = Data()
    while let chunk = try reader.readChunk(process: process) {
        precondition(Date().timeIntervalSince(start) < maxDuration, "reader stuck after exit")
        output.append(chunk)
        if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
    }
    process.waitUntilExit()
    precondition(String(data: output, encoding: .utf8) == expected, "output lost")
    precondition(Date().timeIntervalSince(start) < maxDuration)
}
try check("printf first; sleep 0.1; printf last", "firstlast")
try check("(sleep 2) & printf done", "done", maxDuration: 1)
try check("exit 7", "")
try check("printf tail-without-newline", "tail-without-newline")
print("pipe reader checks passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            main = root / 'main.swift'
            main.write_text('import Foundation\nimport Darwin\nstruct BackendPipeReader {' + reader + harness)
            subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'), str(main), '-o', str(root / 'check')], check=True, capture_output=True, timeout=90)
            result = subprocess.run([str(root / 'check')], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('pipe reader checks passed', result.stdout)
