# XCTest on Linux has no discovery: emit a runner calling every test of every XCTestCase subclass.
import re, sys
calls = []
for path in sys.argv[1:]:
    src = open(path).read()
    for m in re.finditer(r'final class (\w+): XCTestCase \{(.*?)\n\}', src, re.S):
        name, body = m.group(1), m.group(2)
        tests = re.findall(r'func (test\w+)\(\)', body)
        rows = ", ".join(f'("{t}", {name}.{t})' for t in tests)
        calls.append(f"total += shimRun({name}.self, [{rows}])")
print("var total = 0\n" + "\n".join(calls) + '\nprint("core tests: \\(total) run, \\(shimFailures) failed")\nexit(shimFailures == 0 && total > 0 ? 0 : 1)')
