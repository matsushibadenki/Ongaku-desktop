# Synth / UNGE → Ongaku native audio routing

User-requested reuse from `/Users/Shared/Program/Xcode/Synth` and `/Users/littlebuddha/Desktop/alias/UNGE`, 2026-11-11. The original projects are unchanged. `sources.json` identifies the inspected commits and exact snapshot hashes (working copies, not an assertion that every source equals HEAD).

`UNGE/model.rs` and `UNGE/command.rs` preserve the MIT source, including its license. `Synth/` preserves the supplied native adapter and UI/DSP sources. Synth's existing UNGE adaptation is the immediate basis for the new Swift graph; UNGE's source contracts were checked as well.

Adapted executable code:

- `AudioRoutingGraph.swift`: Synth's `FXDocument.layers`, `configuration`, `FXCommand`, and `FXEditor` adapted from UNGE Graph/Command. Direction/single-input checks, stable topological compilation, required active inputs, transactional candidate validation, bounded 64-entry Undo/Redo. Ongaku adds variable UUID nodes (up to 16), explicit revision checks, separate placement, typed stereo ports and local schema version 1.
- `AudioRoutingGraphView.swift`: Synth's scrollable SwiftUI Canvas, shared node/port anchor geometry, cubic cables, header-only drag preview/commit, source-port/input-port connection workflow, selected borders, inspectors, connection removal. Uses Ongaku light/dark tokens and compact localized controls instead of Synth's hardware enclosure colors.
- `AudioRoutingDSP.mm`: Synth `FXStereoLine`'s fixed-capacity circular stereo storage, fractional read and write ported to C++. The new gain, one-pole low-pass, wet/dry feedback delay and mixer are a smaller streaming DSP set, not Synth's entire six-effect engine. The plan executes in the input callback using fixed slots and buffers allocated before capture.

This is a native Swift/Objective-C++ host adaptation, not a Rust FFI or Tauri/wgpu integration. Rust snapshot files are provenance and aren't compiled. No Rust contracts, generated TS types or GPU code were modified; the adapted contracts are verified by Swift/native PCM tests. UNGE's async executor is unsuitable for the audio deadline and isn't invoked. The schemas aren't interchangeable with full UNGE documents or Synth's fixed nine-node presets. No 10,000-node/60-FPS claim is made.

The MIT license is also bundled as `Resources/UNGE-LICENSE.txt` in both Mac products. Synth is user-supplied project code; no additional upstream Synth license is invented. The source and copyright terms of any future imported module must continue to be retained.

日本語：SynthにあるUNGEのSwift移植・ノードUI・ステレオ遅延線をOngakuへ適用したネイティブ構成です。原プロジェクトは変更せず、Rust/Tauri/wgpu全体をリンクしていません。録音中のグラフは固定し、画面側へPCMを渡しません。

简体中文：将Synth中的UNGE Swift适配、节点界面和立体声延迟线适配到Ongaku。未修改原项目，也未链接完整Rust/Tauri/wgpu运行时。录制期间固定路由，不向界面传输PCM。

Follow-up: Ongaku adds a second terminal kind for device output, a bounded native SPSC monitor bridge and an explicit AUHAL device sink. These are Ongaku host additions, not imported UNGE/Synth output code. See docs/quality/AUDIO_NODE_OUTPUT_2026-11-11.md.
