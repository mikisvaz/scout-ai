import io
import sys
import unittest
from contextlib import redirect_stderr

from scout_ai.runner import ScoutRunner


class RunnerStreamingTest(unittest.TestCase):
    def test_run_streams_stderr_when_requested(self):
        code = (
            "import sys; "
            "sys.stderr.write('waiting...\\n'); sys.stderr.flush(); "
            "print('done')"
        )
        runner = ScoutRunner(command=[sys.executable, "-c", code])

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            output = runner._run("ignored", stream_stderr=True)

        self.assertEqual(output.strip(), "done")
        self.assertIn("waiting...", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
