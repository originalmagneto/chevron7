# EmbeddingGemma 2 for security element classification (research, 2026-10-07)

Research only: no code was changed. This note records whether Google's EmbeddingGemma 2 (announced 2026-10-06) is worth trying in Chevron7, where it would fit, and what must be measured before anything ships.

Source: [Google Blog: EmbeddingGemma 2](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/)

## 1. What the model is

- An embedding model: it turns text, images, audio or video into one vector, in a single shared space, so an image crop can be compared directly with a text description.
- 740M parameters in total, modular: about 270M for text only, plus an optional vision encoder (170M) and audio encoder (300M).
- 8K token context (up to 29 images per input).
- 768-dimensional output, truncatable (Matryoshka) to 512, 256 or 128.
- Runs locally through LiteRT, MediaPipe, transformers, sentence-transformers, MLX, llama.cpp, Ollama, LM Studio and others. Core ML is not listed.
- Apache 2.0.
- Benchmarks in the announcement are about text and code (MTEB Code 68.76 to 78.68). Nothing is published about scanned documents, stamps or seals.
- The announcement says "multilingual" without a language list. Slovak is not confirmed.

## 2. Where it fits: the kNN stage of `TwoStageClassifier`

`FeaturePrintClassifier` votes kNN over `ExampleBank` using vectors from `GenerateImageFeaturePrintRequest` (Apple Vision). The vectors come from behind the `FeaturePrintProviding` protocol (`Chevron7Kit/VisionAI/Classification/FeatureVector.swift`), so a new provider is one more conforming type and the pipeline does not change.

Vision feature prints compare an image only with images. With an empty bank (a new user or a fresh install) the kNN stage knows nothing, every crop falls through to `FoundationModelClassifier`, and that is the most expensive part of a run (`DetectionRunStats.modelSeconds`). The learned detector (`LearnedCandidateSource`) does not help here either, because it too needs complete reviews first.

A shared text and image space would allow:

1. **Text prototypes for a cold bank.** One or more descriptions per kind of the 16 in `SecurityElementCatalogue` ("round official stamp with a coat of arms", "binding cord", "wax seal", ...), embedded once and used as kNN examples, so a crop can be judged before any reviewer has confirmed one.
2. **Fewer model calls.** When the kNN stage is confident against those prototypes and the real examples, `TwoStageClassifier` can skip the Foundation Model for that crop.

## 3. Where it does not fit

- **Register search.** Rows are found by evidence number and name, and there are few of them. Plain text search is exact, which a legal record needs.
- **Anything that decides a clause, a record for EZZK, or a signature.** Those stay on fixed rules, never on vector similarity.

## 4. Risks to measure first

1. **Slovak.** Not confirmed. Test Slovak prototype texts against English ones.
2. **Quality on real crops.** Faded stamps, embossing and cords on scans are far from the published benchmarks. Only `vision-eval` on the reviewer's own exported dataset can answer this.
3. **Bank vector format.** Stored examples carry Vision vectors of another length. `FeaturePrintClassifier` already filters by length, but the bank would have to keep both kinds of vector or re-embed from the stored crops (`ExampleBankRecorder` keeps 1200 px PNGs). `FeaturePrintClassifier.exactMatchDistance` (0.05) is calibrated to Vision vectors and would need its own threshold per provider.
4. **Size and runtime.** Bundling 440M parameters (text plus vision) adds hundreds of MB to the DMG. The first experiment should not bundle anything.

## 5. Proposed experiment (no change to the shipped app)

1. A `FeaturePrintProviding` implementation that calls a local Ollama `/api/embed` (`AppSettings.ollamaURL` is already wired for the vision providers), used only by `vision-eval`.
2. Text prototypes per kind, embedded once, injected as kNN examples.
3. Compare on the same exported dataset:
   - Vision feature print, empty bank vs. trained bank;
   - EmbeddingGemma 2, prototypes only vs. prototypes plus trained bank;
   - with and without the Foundation Model stage (`--no-fm`), recording precision, recall, model calls and model seconds.
4. Decide only on numbers: adopt as an optional provider if it beats Vision with an empty bank without losing precision once the bank is trained. Bundling is a separate decision after that.
