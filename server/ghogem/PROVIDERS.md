# GhoGem provider API contracts

Provider transports are implemented in `provider_clients.py`. Only providers
whose docs expose chat completions use the shared JSON/SSE transport; the
remaining services have explicit adapters for their documented wire formats.

## Text and vision chat

| Provider | Request URL | Authentication | Adapter notes | Official docs |
|---|---|---|---|---|
| Groq | `https://api.groq.com/openai/v1/chat/completions` | `Authorization: Bearer <key>` | Maps `max_tokens` to `max_completion_tokens`; omits unsupported message `name`, log-probability, and penalty fields. | [OpenAI compatibility](https://console.groq.com/docs/openai), [API reference](https://console.groq.com/docs/api-reference) |
| Mistral | `https://api.mistral.ai/v1/chat/completions` | `Authorization: Bearer <key>` | Documented chat completions and SSE. `developer` messages are normalized to `system`. | [Chat completions](https://docs.mistral.ai/studio/conversations/chat-completion) |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | `Authorization: Bearer <key>` | Sends the optional application attribution headers `HTTP-Referer` and `X-Title`. | [Create a chat completion](https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion) |
| SambaNova | `https://api.sambanova.ai/v1/chat/completions` | `Authorization: Bearer <key>` | Uses its documented chat body and SSE contract. | [Create chat completion](https://docs.sambanova.ai/docs/api-reference/chat-completions/create-chat-based-completion) |
| Pollinations | `https://gen.pollinations.ai/v1/chat/completions` | Server-only `sk_` key | Server transport is proxy-only (`POLLINATIONS_SOCKS_PROXY`, or the process's proxychains route); no direct fallback. Flutter calls the GhoGem proxy route. Model IDs and optional parameters are checked against `/v1/models`. | [API recipes](https://github.com/pollinations/pollinations/blob/main/gen.pollinations.ai/src/docs/apidocs-recipes.md), [Models](https://github.com/pollinations/pollinations/blob/main/gen.pollinations.ai/src/docs/models.md) |
| BazaarLink | `https://api.bazaarlink.ai/v1/chat/completions` | `Authorization: Bearer <key>` | OpenAI-compatible messages, tools, and multimodal content. | [API docs](https://bazaarlink.ai/en/docs) |
| ZvenoAI | `https://api.zveno.ai/v1/chat/completions` | `Authorization: Bearer <key>` | Docs explicitly describe chat completions, SSE, tools, vision, and structured output. | [Chat completions](https://zveno.ai/docs/api-reference/chat-completions) |
| Vireonix | `https://vireonix.ai/v1/chat/completions` | No Authorization header | Public model ID is `auto`; docs advertise chat/SSE but do not document tools, so Work tool calls do not use this provider. | [API docs](https://vireonix.ai/docs) |
| PersorAI | `https://persorai.com/v1/chat/completions` | `Authorization: Bearer any-random-key` when no user value is supplied | The service documents that no account is needed and any bearer value is accepted. | [Official API page](https://persorai.com/) |
| Free.ai | `https://api.free.ai/v1/chat/` | `Authorization: Bearer sk-free-…` | Provider-specific path; accepts chat messages and returns OpenAI-shaped choices. | [API docs](https://free.ai/api/) |
| CVRON | `GET https://cvron.alwaysdata.net/cvronai/multi-llm.php?model=…&prompt=…` | None | Custom query adapter; plain JSON response. The service does not document chat completions, tools, or SSE. | [Official API hub](https://cvron.alwaysdata.net/) |
| VisionSter | `POST https://www.ahm7xmakki.com/api/imgchat` | None | Custom image adapter using `userPrompt`, `image` or `url`, and optional `messages`; response text is `response`. | [Image chat docs](https://www.ahm7xmakki.com/imgchat) |

## Speech transcription

| Provider | Request URL | Authentication | Wire format | Official docs |
|---|---|---|---|---|
| Groq | `https://api.groq.com/openai/v1/audio/transcriptions` | Groq bearer key | Multipart `file`, `model=whisper-large-v3`, `language=ru`. | [Groq API reference](https://console.groq.com/docs/api-reference) |
| STT.ai | `https://api.stt.ai/v1/transcribe` | `STTAI_API_KEY` bearer key | Multipart `file`, `model=large-v3-turbo`, language and diarization fields. | [API docs](https://stt.ai/api/) |

## Key handling

- Pollinations secret keys (`sk_…`) stay on the server and are never stored in
  the Flutter app. Its chat traffic always uses the GhoGem proxy endpoint.
- The seven credentialed APIs available as direct Flutter BYOK are listed in
  the key screen. Pollinations' key is server-only. Vireonix, CVRON, and
  VisionSter do not receive Authorization headers.
- `any-random-key` is only used for PersorAI because its own docs show that
  exact no-account bearer behavior; it is not sent to other providers.
