// Probe: main [hang|exit|none|ok]; "middle" starts a 10-min sleeper with stdio ignored, then exits.
const { spawn } = require("node:child_process");
const [mode] = process.argv.slice(2);
if (mode === "middle") {
  spawn(process.execPath, [__filename, "sleep"], { stdio: "ignore" });
  process.exit(0);
} else if (mode === "sleep") {
  setTimeout(() => {}, 600_000);
} else {
  if (mode === "hang" || mode === "exit") spawn(process.execPath, [__filename, "middle"], { stdio: "ignore" });
  console.log(`main ${process.pid} mode=${mode}`);
  if (mode === "hang" || mode === "none") setTimeout(() => {}, 600_000);
}
