// Native GPU UI for Electrobun: HTML/CSS/JSX rendered by the Zig UI core
// straight into a WGPU view — no webview. JSX uses the same warren DOM
// renderer as the browser, so components are portable between the two.
//
//   import { createNativeUI } from "electrobun/main/native-ui";
//   const win = new GpuWindow({ title: "App", frame: { width: 800, height: 600 } });
//   const ui = createNativeUI(win, { css });
//   ui.render(() => <App />);
import { JSCallback, ptr } from "bun:ffi";
import { render as domRender } from "../../../../browser/ui/dom";
import { native as wgpuNative } from "../../webGPU";
import { uiLib, isNativeUIAvailable } from "./ffi";
import { NativeDocument, NativeElement } from "./document";

export { isNativeUIAvailable, NativeDocument, NativeElement };
export type { NativeEvent } from "./document";

const enc = new TextEncoder();

type ViewLike = { ptr: unknown } | { wgpuView: { ptr: unknown } };

function viewPointer(target: ViewLike): unknown {
	if ("wgpuView" in target && target.wgpuView) return target.wgpuView.ptr;
	return (target as { ptr: unknown }).ptr;
}

export interface NativeUIOptions {
	/** CSS stylesheets to add (strings) */
	css?: string | string[];
	/** follow / force the color scheme for prefers-color-scheme */
	dark?: boolean;
}

export class NativeUI {
	readonly id: number;
	readonly document: NativeDocument;
	private wakeup: JSCallback | null = null;
	private poll: ReturnType<typeof setInterval> | null = null;
	private sheets: number[] = [];

	constructor(target: ViewLike, options: NativeUIOptions = {}) {
		const lib = uiLib();
		this.id = lib.ebui_create();
		if (!this.id) throw new Error("electrobun native UI: failed to create instance");
		this.document = new NativeDocument(this.id);
		const view = viewPointer(target);
		if (!view) throw new Error("electrobun native UI: target has no WGPU view");
		const dawn = wgpuNative.path ? enc.encode(wgpuNative.path + "\0") : null;
		const ok = lib.ebui_attach_wgpu_view(this.id, view as any, dawn ? ptr(dawn) : null);
		if (!ok) throw new Error("electrobun native UI: could not attach to the WGPU view (is bundleWGPU enabled?)");
		for (const css of ([] as string[]).concat(options.css ?? [])) this.addStylesheet(css);
		if (options.dark !== undefined) lib.ebui_set_dark(this.id, options.dark);
		this.startEventPump();
	}

	private startEventPump() {
		const lib = uiLib();
		try {
			// native input arrives on the main thread; wake the JS thread to drain it
			this.wakeup = new JSCallback(() => queueMicrotask(() => this.document.pump()), {
				args: ["ptr"],
				returns: "void",
				threadsafe: true,
			});
			lib.ebui_set_wakeup(this.id, this.wakeup.ptr, null);
		} catch {
			this.wakeup = null;
		}
		// safety net (runtimes without thread-safe callbacks)
		this.poll = setInterval(() => this.document.pump(), this.wakeup ? 250 : 16);
	}

	addStylesheet(css: string): number {
		const b = enc.encode(css);
		const h = uiLib().ebui_add_stylesheet(this.id, ptr(b.length ? b : new Uint8Array(1)), b.length);
		this.sheets.push(h);
		return h;
	}

	removeStylesheet(handle: number): void {
		uiLib().ebui_remove_stylesheet(this.id, handle);
	}

	/** Mount a warren app (JSX) into the native document body. */
	render(app: () => unknown): () => void {
		return domRender(app as any, this.document.body as unknown as Element);
	}

	get body(): NativeElement {
		return this.document.body;
	}

	destroy(): void {
		if (this.poll) clearInterval(this.poll);
		this.document.dispose();
		const lib = uiLib();
		lib.ebui_detach_view(this.id);
		lib.ebui_destroy(this.id);
		this.wakeup?.close();
	}
}

export function createNativeUI(target: ViewLike, options?: NativeUIOptions): NativeUI {
	return new NativeUI(target, options);
}
