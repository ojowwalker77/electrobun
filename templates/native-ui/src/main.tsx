// Electrobun native UI: the same JSX you'd write for the browser (warren's
// DOM renderer), rendered by the Zig UI core directly into a WGPU view.
// No webview, no browser engine — HTML elements + CSS + fine-grained
// reactivity, painted by Dawn.
import { GpuWindow } from "electrobun/main/gpu-window";
import { createNativeUI, live, signal, store, For, Show } from "electrobun/main/native-ui";

const css = `
:root { --bg: #f5f6fa; --card: #fff; --ink: #1d2230; --muted: #858b9c; --line: #eceef3; --brand: oklch(58% 0.2 265); }
@media (prefers-color-scheme: dark) { :root { --bg: #0f1117; --card: #171a22; --ink: #e8eaf0; --muted: #7c8296; --line: #232733; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 14px system-ui; height: 100vh; display: flex; }
aside { width: 210px; background: #12141c; color: #c9ccd6; padding: 18px 12px; display: flex; flex-direction: column; gap: 2px; app-region: drag; padding-top: 44px; }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 16px; color: white; margin: 0 8px 18px; }
.logo { width: 24px; height: 24px; border-radius: 7px; background: linear-gradient(135deg, #60a5fa, #a78bfa); box-shadow: 0 4px 12px rgba(99,102,241,.4); }
.nav { padding: 8px 10px; border-radius: 8px; color: #8d92a3; cursor: pointer; app-region: no-drag; transition: background-color .15s, color .15s; }
.nav:hover { background: #1b1e29; color: #d7dae3; }
.nav.active { background: #232736; color: white; }
main { flex: 1; padding: 28px; display: flex; flex-direction: column; gap: 18px; overflow: auto; }
h1 { margin: 0; font-size: 24px; letter-spacing: -.5px; }
.sub { color: var(--muted); margin-top: 4px; }
.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
.card { background: var(--card); border-radius: 14px; padding: 16px; box-shadow: 0 1px 2px rgba(0,0,0,.05), 0 10px 28px rgba(20,24,40,.07); }
.stat { font-size: 30px; font-weight: 750; margin-top: 4px; font-variant-numeric: tabular-nums; }
.row { display: flex; gap: 10px; align-items: center; }
button { font: inherit; border: none; border-radius: 9px; padding: 8px 14px; background: var(--brand); color: white; font-weight: 600; cursor: pointer; transition: transform .12s, box-shadow .12s; }
button:hover { transform: translateY(-1px); box-shadow: 0 6px 16px rgba(80,90,220,.3); }
button.ghost { background: transparent; color: var(--ink); border: 1px solid var(--line); }
input.text { flex: 1; font: inherit; padding: 9px 12px; border-radius: 9px; border: 1px solid var(--line); background: var(--bg); color: var(--ink); }
ul { list-style: none; margin: 0; padding: 0; }
li { display: flex; align-items: center; gap: 10px; padding: 10px 2px; border-bottom: 1px solid var(--line); }
li:last-child { border-bottom: none; }
li.done span { color: var(--muted); text-decoration: line-through; }
.pill { font-size: 12px; padding: 2px 8px; border-radius: 99px; background: #eef0ff; color: #4f46e5; font-weight: 600; }
.bar { height: 8px; border-radius: 99px; background: var(--line); overflow: hidden; }
.bar > div { height: 100%; background: linear-gradient(90deg, #6366f1, #ec4899); border-radius: 99px; transition: width .35s ease-out; }
`;

const win = new GpuWindow({
	title: "Native UI",
	frame: { x: 160, y: 120, width: 960, height: 640 },
	titleBarStyle: "hiddenInset",
});

const ui = createNativeUI(win, { css });

const [count, setCount] = signal(0);
const [state, setState] = store({
	draft: "",
	todos: [
		{ id: 1, title: "Render HTML/CSS natively", done: true },
		{ id: 2, title: "Fine-grained reactivity in the core", done: false },
		{ id: 3, title: "Share components with the browser", done: false },
	],
});
let nextId = 4;
const [page, setPage] = signal("Dashboard");

function addTodo() {
	const title = state.draft.trim();
	if (!title) return;
	setState((s) => {
		s.todos.push({ id: nextId++, title, done: false });
		s.draft = "";
	});
}

function App() {
	const pages = ["Dashboard", "Projects", "Team", "Settings"];
	return (
		<>
			<aside>
				<div class="brand">
					<div class="logo" />
					Electrobun
				</div>
				<For each={pages}>
					{(p) => (
						<div class={live(() => (page() === p ? "nav active" : "nav"))} onClick={() => setPage(p)}>
							{p}
						</div>
					)}
				</For>
			</aside>
			<main>
				<div>
					<h1>{live(() => page())}</h1>
					<div class="sub">HTML + CSS + JSX, rendered by the Zig UI core with Dawn — no webview.</div>
				</div>
				<div class="grid">
					<div class="card">
						<div class="sub">Clicks</div>
						<div class="stat">{live(() => count())}</div>
						<div class="row" style="margin-top: 10px">
							<button onClick={() => setCount((c) => c + 1)}>Increment</button>
							<button class="ghost" onClick={() => setCount(0)}>Reset</button>
						</div>
					</div>
					<div class="card">
						<div class="sub">Completed</div>
						<div class="stat">
							{live(() => state.todos.filter((t) => t.done).length)} / {live(() => state.todos.length)}
						</div>
						<div class="bar" style="margin-top: 14px">
							<div style={live(() => `width: ${(state.todos.filter((t) => t.done).length / Math.max(1, state.todos.length)) * 100}%`)} />
						</div>
					</div>
					<div class="card">
						<div class="sub">Renderer</div>
						<div class="stat">GPU</div>
						<span class="pill">Dawn · Metal</span>
					</div>
				</div>
				<div class="card">
					<div class="row" style="margin-bottom: 8px">
						<input
							class="text"
							placeholder="Add a task…"
							value={live(() => state.draft)}
							onInput={(e: any) => setState((s) => void (s.draft = e.target.value))}
							onKeyDown={(e: any) => e.key === "Enter" && addTodo()}
						/>
						<button onClick={addTodo}>Add</button>
					</div>
					<ul>
						<For each={live(() => state.todos)} key={(t) => t.id}>
							{(t) => (
								<li class={live(() => (t.done ? "done" : ""))}>
									<input
										type="checkbox"
										checked={live(() => t.done)}
										onChange={() => setState((s) => void (s.todos.find((x) => x.id === t.id)!.done = !t.done))}
									/>
									<span style="flex: 1">{t.title}</span>
									<button class="ghost" onClick={() => setState((s) => void s.todos.splice(s.todos.findIndex((x) => x.id === t.id), 1))}>
										Remove
									</button>
								</li>
							)}
						</For>
					</ul>
					<Show when={live(() => state.todos.length === 0)}>
						<div class="sub" style="text-align: center; padding: 18px">All done 🎉</div>
					</Show>
				</div>
			</main>
		</>
	);
}

ui.render(App);
