# Sextant 🧭

Type-safe JSON Schema generation and validation for Gleam.

[![Package Version](https://img.shields.io/hexpm/v/sextant)](https://hex.pm/packages/sextant)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/sextant/)

```sh
gleam add sextant
```

## Why Sextant?

### Generate OpenAPI schemas for your API

Export your schemas as JSON Schema 2020-12 for API documentation, client generation, or contract testing:

```gleam
import gleam/json

type CreateUserRequest {
  CreateUserRequest(
    email: String,
    name: String,
    role: Role,
  )
}

type Role {
  Admin
  User
  Guest
}

fn create_user_schema() -> sextant.JsonSchema(CreateUserRequest) {
  use email <- sextant.field("email",
    sextant.string()
    |> sextant.format(sextant.Email)
    |> sextant.describe("User's email address"))
  use name <- sextant.field("name",
    sextant.string()
    |> sextant.min_length(1)
    |> sextant.max_length(100))
  use role <- sextant.field("role",
    sextant.enum(#("admin", Admin), [#("user", User), #("guest", Guest)]))
  sextant.success(CreateUserRequest(email:, name:, role:))
}

pub fn get_openapi_schema() -> String {
  create_user_schema()
  |> sextant.to_json
  |> json.to_string
}
// {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"email":{"type":"string","format":"email","description":"User's email address"},...}}
```

### Work with typed UUIDs and timestamps

Sextant provides typed schemas for common formats that decode directly to Gleam types:

```gleam
import gleam/time/timestamp.{type Timestamp}
import youid/uuid.{type Uuid}

type AuditLog {
  AuditLog(
    id: Uuid,
    timestamp: Timestamp,
    actor_id: Uuid,
    action: String,
  )
}

fn audit_log_schema() -> sextant.JsonSchema(AuditLog) {
  use id <- sextant.field("id", sextant.uuid())
  use timestamp <- sextant.field("timestamp", sextant.timestamp())
  use actor_id <- sextant.field("actor_id", sextant.uuid())
  use action <- sextant.field("action", sextant.string())
  sextant.success(AuditLog(id:, timestamp:, actor_id:, action:))
}
// JSON: {"id": "550e8400-e29b-41d4-a716-446655440000", "timestamp": "2024-01-15T10:30:00Z", ...}
// Gleam: AuditLog(id: Uuid, timestamp: Timestamp, ...)
```

### Generate structured outputs from LLMs

Use your schema to guide LLM outputs and validate responses:

```gleam
type SentimentAnalysis {
  SentimentAnalysis(
    sentiment: Sentiment,
    confidence: Float,
    key_phrases: List(String),
  )
}

type Sentiment {
  Positive
  Negative
  Neutral
}

fn sentiment_schema() -> sextant.JsonSchema(SentimentAnalysis) {
  use sentiment <- sextant.field("sentiment",
    sextant.enum(#("positive", Positive), [#("negative", Negative), #("neutral", Neutral)]))
  use confidence <- sextant.field("confidence",
    sextant.number() |> sextant.float_min(0.0) |> sextant.float_max(1.0))
  use key_phrases <- sextant.field("key_phrases",
    sextant.array(of: sextant.string()) |> sextant.max_items(5))
  sextant.success(SentimentAnalysis(sentiment:, confidence:, key_phrases:))
}

pub fn analyse_text(text: String) -> Result(SentimentAnalysis, String) {
  // Pass the schema to the LLM for structured output, then validate
  let json_schema = sextant.to_json(sentiment_schema())
  use response <- result.try(generate_structured(text, json_schema))

  case sextant.run(response.object, sentiment_schema()) {
    Ok(analysis) -> Ok(analysis)
    Error(errors) -> Error("LLM returned invalid response")
  }
}
```

## Contributing

```sh
gleam test              # Run tests
gleam test --target js  # Run tests on JavaScript
```

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/sextant/).
