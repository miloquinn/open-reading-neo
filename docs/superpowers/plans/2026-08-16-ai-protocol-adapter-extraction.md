# AI Protocol Adapter Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move provider-specific endpoint, header, payload, and successful-response conversion out of `ReaderHttpAIService`.

**Architecture:** Add a stateless `AIProtocolAdapter` in a separate part file of the AI library. The HTTP service retains request orchestration, prompt preparation, JSON decoding, and network/error translation while delegating all OpenAI, Anthropic, Gemini, and MiniMax wire-format decisions.

**Tech Stack:** Dart, Dio, JSON-compatible maps, `flutter_test`.

## Global Constraints

- Preserve all existing endpoint strings, headers, timeouts, payload fields, and response extraction behavior.
- Preserve existing `ai_service.dart` import compatibility.
- Do not change error mapping, prompt text, model validation, or persistence behavior.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock protocol contracts directly

**Files:**
- Create: `test/ai_protocol_adapter_test.dart`

**Interfaces:**
- Consumes: `AIProtocolAdapter` and `AIProviderSettings`.
- Produces: Direct wire-format tests independent of Dio request execution.

- [x] **Step 1: Test OpenAI-compatible conversion**

Assert chat/model endpoints, bearer header, message payload, temperature, stream flag, and both string/list content responses.

- [x] **Step 2: Test Anthropic conversion**

Assert `/v1/messages`, model-list endpoint, API headers, separated system prompt, typed text blocks, max tokens, clamped temperature, and multi-block response concatenation.

- [x] **Step 3: Test Gemini conversion**

Assert model-qualified generation endpoint, API header, system instruction, assistant-to-model role mapping, generation config, model-list endpoint, and candidate-part concatenation.

- [x] **Step 4: Test MiniMax temperature handling**

Assert the OpenAI-compatible payload retains its special `0.01...1.0` temperature clamp.

### Task 2: Extract the protocol adapter

**Files:**
- Create: `lib/reader_core/ai/ai_protocol_adapter.dart`
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Produces: `AIProtocolAdapter.chatEndpoint`, `modelListEndpoint`, `requestOptions`, `buildPayload`, and `extractAssistantContent`.
- Consumes: Existing provider/protocol settings and Dio `Options`.

- [x] **Step 1: Declare the adapter part file**

Add `part 'ai_protocol_adapter.dart';` to the AI library.

- [x] **Step 2: Move endpoint and header construction**

Move both chat/model endpoints and request options without changing timeouts or response type.

- [x] **Step 3: Move request payload conversion**

Move OpenAI/MiniMax, Anthropic, and Gemini payload branches intact.

- [x] **Step 4: Move successful response extraction**

Move string/list OpenAI content, Anthropic text blocks, and Gemini candidate parts intact.

### Task 3: Delegate from the HTTP service

**Files:**
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Consumes: `AIProtocolAdapter`.
- Produces: `ReaderHttpAIService({Dio? dio, AISettingsStore? settingsStore, AIProtocolAdapter? protocolAdapter})`.

- [x] **Step 1: Inject the protocol adapter**

Default to a const adapter and preserve existing constructor call sites.

- [x] **Step 2: Delegate model-list requests**

Use adapter model endpoint and options while retaining the model-list response parsing and error translation in the service.

- [x] **Step 3: Delegate chat wire conversion**

Use adapter endpoint, payload, options, and content extraction while retaining prompt construction, JSON decoding, empty-response enforcement, and network exceptions.

### Task 4: Verify extraction

**Files:**
- Verify: `lib/reader_core/ai/ai_service.dart`
- Verify: `lib/reader_core/ai/ai_protocol_adapter.dart`
- Verify: `test/ai_protocol_adapter_test.dart`
- Verify: `test/ai_service_models_test.dart`

**Interfaces:**
- Consumes: Extracted protocol boundary.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/reader_core/ai/ai_service.dart lib/reader_core/ai/ai_protocol_adapter.dart test/ai_protocol_adapter_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused AI tests**

Run:

```bash
flutter test test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart test/settings_page_test.dart
```

Expected: all tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all accumulated tests pass.
