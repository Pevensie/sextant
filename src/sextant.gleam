//// Sextant - A Gleam library for JSON Schema generation and validation.
////
//// This library provides a `use`-based API for defining JSON schemas that can
//// both generate JSON Schema 2020-12 documents and validate dynamic data.
////
//// ## Example
////
//// ```gleam
//// import sextant
//// import gleam/option.{type Option}
////
//// type User {
////   User(name: String, age: Int, email: Option(String))
//// }
////
//// fn user_schema() -> sextant.JsonSchema(User) {
////   use name <- sextant.field("name", sextant.string() |> sextant.min_length(1))
////   use age <- sextant.field("age", sextant.integer() |> sextant.int_min(0))
////   use email <- sextant.optional_field("email", sextant.string())
////   sextant.success(User(name:, age:, email:))
//// }
////
//// // Generate JSON Schema
//// let schema_json = sextant.to_json(user_schema())
////
//// // Validate data
//// let result = sextant.run(dynamic_data, user_schema())
//// ```
////
//// ## Note
////
//// When schemas are converted to JSON, the values used will be the zero values for
//// each type. As such, creating self-referential schemas will result in asymmetry.
//// The generated JSON Schema will use the zero values, while the computed values
//// will be used during validation.
////
//// Consider the following schema:
////
//// ```gleam
//// fn self_referential_schema() {
////   use wibble <- sextant.field("wibble", sextant.string())
////   use wobble <- sextant.field(
////     "wobble",
////     sextant.string() |> sextant.const_value(wibble, json.string),
////   )
////   sextant.success(#(wibble, wobble))
//// }
//// ```
////
//// The value of `wobble` is computed from the value of `wibble`. When generating the
//// JSON Schema, we don't have a known value for `wibble`, so we use the zero value
//// for a string field, which is the empty string (`""`).
////
//// This results in the following schema:
////
//// ```json
//// {
////   "$schema": "https://json-schema.org/draft/2020-12/schema",
////   "required": ["wibble", "wobble"],
////   "type": "object",
////   "properties": {
////     "wibble": {
////       "type": "string"
////     },
////     "wobble": {
////       "const": ""
////     }
////   },
////   "additionalProperties": false
//// }
//// ```
////
//// When validating the data, the value of `wobble` is computed from the value of
//// `wibble` correctly.
////
//// ```gleam
//// // Data is invalid as the expected value for wobble is computed
//// // from the value of wibble
//// let invalid_data =
////   dynamic.properties([
////     #(dynamic.string("wibble"), dynamic.string("value")),
////     #(dynamic.string("wobble"), dynamic.string("not-value")),
////   ])
////
//// let assert Error([
////   sextant.ConstMismatch(
////     expected: "\"value\"",
////     actual: "\"not-value\"",
////     path: ["wobble"],
////   ),
//// ]) = sextant.run(invalid_data, self_referential_schema())
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import youid/uuid.{type Uuid}

// ---------------------------------------------------------------------------
// Schema Definition Types (internal)
// ---------------------------------------------------------------------------

/// Schema definition that maps to JSON Schema structure
type SchemaDefinition {
  StringSchema(constraints: StringConstraints, meta: Metadata)
  IntegerSchema(constraints: IntConstraints, meta: Metadata)
  NumberSchema(constraints: FloatConstraints, meta: Metadata)
  BooleanSchema(meta: Metadata)
  NullSchema(meta: Metadata)
  ArraySchema(
    items: SchemaDefinition,
    constraints: ArrayConstraints,
    meta: Metadata,
  )
  ObjectSchema(
    properties: List(Property),
    required: List(String),
    additional_properties: Bool,
    meta: Metadata,
  )
  DictSchema(values: SchemaDefinition, meta: Metadata)
  NullableSchema(inner: SchemaDefinition, meta: Metadata)
  OneOfSchema(variants: List(SchemaDefinition), meta: Metadata)
  AnyOfSchema(variants: List(SchemaDefinition), meta: Metadata)
  EnumSchema(values: List(String), meta: Metadata)
  ConstSchema(value: json.Json, meta: Metadata)
  TupleSchema(items: List(SchemaDefinition), meta: Metadata)
}

/// Object property definition
type Property {
  Property(name: String, schema: SchemaDefinition)
}

/// Schema metadata (title, description, etc.)
type Metadata {
  Metadata(
    title: Option(String),
    description: Option(String),
    examples: List(json.Json),
    default: Option(json.Json),
  )
}

const empty_metadata = Metadata(
  title: None,
  description: None,
  examples: [],
  default: None,
)

/// String-specific constraints
type StringConstraints {
  StringConstraints(
    min_length: Option(Int),
    max_length: Option(Int),
    pattern: Option(String),
    format: Option(StringFormat),
  )
}

const empty_string_constraints = StringConstraints(
  min_length: None,
  max_length: None,
  pattern: None,
  format: None,
)

/// Integer constraints
type IntConstraints {
  IntConstraints(
    minimum: Option(Int),
    maximum: Option(Int),
    exclusive_minimum: Option(Int),
    exclusive_maximum: Option(Int),
    multiple_of: Option(Int),
  )
}

const empty_int_constraints = IntConstraints(
  minimum: None,
  maximum: None,
  exclusive_minimum: None,
  exclusive_maximum: None,
  multiple_of: None,
)

/// Float/number constraints
type FloatConstraints {
  FloatConstraints(
    minimum: Option(Float),
    maximum: Option(Float),
    exclusive_minimum: Option(Float),
    exclusive_maximum: Option(Float),
    multiple_of: Option(Float),
  )
}

const empty_float_constraints = FloatConstraints(
  minimum: None,
  maximum: None,
  exclusive_minimum: None,
  exclusive_maximum: None,
  multiple_of: None,
)

/// Array constraints
type ArrayConstraints {
  ArrayConstraints(
    min_items: Option(Int),
    max_items: Option(Int),
    unique_items: Bool,
  )
}

const empty_array_constraints = ArrayConstraints(
  min_items: None,
  max_items: None,
  unique_items: False,
)

// ---------------------------------------------------------------------------
// Public Types
// ---------------------------------------------------------------------------

/// String format types as defined in JSON Schema.
pub type StringFormat {
  Email
  Uri
  DateTime
  Date
  Time
  Uuid
  Hostname
  Ipv4
  Ipv6
}

/// String-specific constraint violations.
pub type StringConstraintViolation {
  StringTooShort(min: Int, actual: Int)
  StringTooLong(max: Int, actual: Int)
  PatternMismatch(pattern: String, actual: String)
  InvalidPattern(pattern: String, error: String)
  InvalidFormat(format: String, actual: String)
}

/// Number-specific constraint violations (applies to both Int and Float).
pub type NumberConstraintViolation {
  NumberTooSmall(minimum: Float, exclusive: Bool, actual: Float)
  NumberTooLarge(maximum: Float, exclusive: Bool, actual: Float)
  NotMultipleOf(multiple: Float, actual: Float)
}

/// Array-specific constraint violations.
pub type ArrayConstraintViolation {
  ArrayTooShort(min: Int, actual: Int)
  ArrayTooLong(max: Int, actual: Int)
  ItemsNotUnique
}

/// Union type for all constraint violations.
pub type ConstraintViolation {
  StringViolation(StringConstraintViolation)
  NumberViolation(NumberConstraintViolation)
  ArrayViolation(ArrayConstraintViolation)
  /// Custom validation error from [`try_map`](#try_map) or other user-defined validations.
  CustomViolation(message: String)
}

/// Top-level validation error returned when schema validation fails.
pub type ValidationError {
  TypeError(expected: String, found: String, path: List(String))
  ConstraintError(violation: ConstraintViolation, path: List(String))
  MissingField(field: String, path: List(String))
  UnknownVariant(value: String, expected: List(String), path: List(String))
  ConstMismatch(expected: String, actual: String, path: List(String))
}

/// Convert a validation error to a human-readable string.
pub fn error_to_string(error: ValidationError) -> String {
  case error {
    TypeError(expected, found, path) ->
      "Expected " <> expected <> ", got " <> found <> format_path(path)
    ConstraintError(violation, path) ->
      constraint_violation_to_string(violation) <> format_path(path)
    MissingField(field, path) ->
      "Missing required field '" <> field <> "'" <> format_path(path)
    UnknownVariant(value, expected, path) ->
      "Unknown variant '"
      <> value
      <> "', expected one of: "
      <> string.join(expected, ", ")
      <> format_path(path)
    ConstMismatch(expected, actual, path) ->
      "Expected const value "
      <> expected
      <> ", got "
      <> actual
      <> format_path(path)
  }
}

fn format_path(path: List(String)) -> String {
  case path {
    [] -> ""
    _ -> " at '" <> string.join(path, ".") <> "'"
  }
}

fn constraint_violation_to_string(violation: ConstraintViolation) -> String {
  case violation {
    StringViolation(v) -> string_violation_to_string(v)
    NumberViolation(v) -> number_violation_to_string(v)
    CustomViolation(msg) -> msg
    ArrayViolation(v) -> array_violation_to_string(v)
  }
}

fn string_violation_to_string(violation: StringConstraintViolation) -> String {
  case violation {
    StringTooShort(min, actual) ->
      "String too short (minimum: "
      <> int.to_string(min)
      <> ", got: "
      <> int.to_string(actual)
      <> ")"
    StringTooLong(max, actual) ->
      "String too long (maximum: "
      <> int.to_string(max)
      <> ", got: "
      <> int.to_string(actual)
      <> ")"
    PatternMismatch(pattern, actual) ->
      "String '" <> actual <> "' does not match pattern '" <> pattern <> "'"
    InvalidPattern(pattern, error) ->
      "Invalid regex pattern '" <> pattern <> "': " <> error
    InvalidFormat(format_name, actual) ->
      "String '" <> actual <> "' is not a valid " <> format_name
  }
}

fn number_violation_to_string(violation: NumberConstraintViolation) -> String {
  case violation {
    NumberTooSmall(minimum, exclusive, actual) -> {
      let op = case exclusive {
        True -> "greater than"
        False -> "at least"
      }
      "Number must be "
      <> op
      <> " "
      <> float.to_string(minimum)
      <> ", got: "
      <> float.to_string(actual)
    }
    NumberTooLarge(maximum, exclusive, actual) -> {
      let op = case exclusive {
        True -> "less than"
        False -> "at most"
      }
      "Number must be "
      <> op
      <> " "
      <> float.to_string(maximum)
      <> ", got: "
      <> float.to_string(actual)
    }
    NotMultipleOf(multiple, actual) ->
      "Number "
      <> float.to_string(actual)
      <> " is not a multiple of "
      <> float.to_string(multiple)
  }
}

fn array_violation_to_string(violation: ArrayConstraintViolation) -> String {
  case violation {
    ArrayTooShort(min, actual) ->
      "Array too short (minimum: "
      <> int.to_string(min)
      <> " items, got: "
      <> int.to_string(actual)
      <> ")"
    ArrayTooLong(max, actual) ->
      "Array too long (maximum: "
      <> int.to_string(max)
      <> " items, got: "
      <> int.to_string(actual)
      <> ")"
    ItemsNotUnique -> "Array items are not unique"
  }
}

/// Options for controlling schema validation behaviour.
///
/// Use these options with [`run_with_options`](#run_with_options) to customize
/// validation. The default options are available as [`default_options`](#default_options).
///
/// ## Example
///
/// ```gleam
/// // Enable format validation (disabled by default per JSON Schema spec)
/// let opts = sextant.Options(validate_formats: True)
/// sextant.run_with_options(data, email_schema, opts)
/// ```
pub type Options {
  Options(
    /// Whether to validate string formats (email, uri, etc.).
    /// Disabled by default as per JSON Schema specification, which treats
    /// formats as annotations rather than assertions.
    validate_formats: Bool,
  )
}

/// Default validation options.
///
/// - `validate_formats`: `False` (formats are treated as annotations only)
pub const default_options = Options(validate_formats: False)

/// Check if errors contain a type error (vs only constraint errors).
/// Type errors mean we can't run further constraints on the value.
fn has_type_error(errors: List(ValidationError)) -> Bool {
  list.any(errors, fn(e) {
    case e {
      TypeError(_, _, _) -> True
      MissingField(_, _) -> True
      _ -> False
    }
  })
}

/// A JSON Schema that can generate schema documents and validate data.
///
/// The type parameter `a` is the Gleam type that this schema decodes to.
pub opaque type JsonSchema(a) {
  JsonSchema(
    schema: SchemaDefinition,
    decoder: fn(Dynamic, Options) -> #(a, List(ValidationError)),
    /// A zero/default value used internally for schema extraction.
    /// This value is never exposed to users and is only used when we need
    /// to call continuations to build the schema structure.
    zero: a,
  )
}

// ---------------------------------------------------------------------------
// Primitive Schemas
// ---------------------------------------------------------------------------

/// Create a schema for JSON strings.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string()
/// ```
pub fn string() -> JsonSchema(String) {
  JsonSchema(
    schema: StringSchema(empty_string_constraints, empty_metadata),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.string) |> result.replace_error(Nil) {
        Ok(s) -> #(s, [])
        Error(_) -> #("", [
          TypeError("String", dynamic.classify(data), []),
        ])
      }
    },
    zero: "",
  )
}

/// Create a schema for JSON integers.
///
/// ## Example
///
/// ```gleam
/// let age_schema = sextant.integer()
/// ```
pub fn integer() -> JsonSchema(Int) {
  JsonSchema(
    schema: IntegerSchema(empty_int_constraints, empty_metadata),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.int) |> result.replace_error(Nil) {
        Ok(i) -> #(i, [])
        Error(_) -> #(0, [
          TypeError("Int", dynamic.classify(data), []),
        ])
      }
    },
    zero: 0,
  )
}

/// Create a schema for JSON numbers (floats).
///
/// ## Example
///
/// ```gleam
/// let price_schema = sextant.number()
/// ```
pub fn number() -> JsonSchema(Float) {
  JsonSchema(
    schema: NumberSchema(empty_float_constraints, empty_metadata),
    decoder: fn(data, _opts) {
      // Try float first, then fall back to int and convert
      case decode.run(data, decode.float) {
        Ok(f) -> #(f, [])
        Error(_) ->
          case decode.run(data, decode.int) {
            Ok(i) -> #(int.to_float(i), [])
            Error(_) -> #(0.0, [
              TypeError("Float", dynamic.classify(data), []),
            ])
          }
      }
    },
    zero: 0.0,
  )
}

/// Create a schema for JSON booleans.
///
/// ## Example
///
/// ```gleam
/// let active_schema = sextant.boolean()
/// ```
pub fn boolean() -> JsonSchema(Bool) {
  JsonSchema(
    schema: BooleanSchema(empty_metadata),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.bool) |> result.replace_error(Nil) {
        Ok(b) -> #(b, [])
        Error(_) -> #(False, [
          TypeError("Bool", dynamic.classify(data), []),
        ])
      }
    },
    zero: False,
  )
}

/// Create a schema for JSON null.
///
/// ## Example
///
/// ```gleam
/// let null_schema = sextant.null()
/// ```
pub fn null() -> JsonSchema(Nil) {
  JsonSchema(
    schema: NullSchema(empty_metadata),
    decoder: fn(data, _opts) {
      case is_null(data) {
        True -> #(Nil, [])
        False -> #(Nil, [
          TypeError("Null", dynamic.classify(data), []),
        ])
      }
    },
    zero: Nil,
  )
}

// ---------------------------------------------------------------------------
// Typed Schemas (UUID, Timestamp, URI)
// ---------------------------------------------------------------------------

/// Create a schema for UUIDs that decodes to `youid/uuid.Uuid`.
///
/// This validates and parses the string as a UUID, returning the proper
/// `Uuid` type from the `youid` library. Use this instead of
/// `string() |> format(Uuid)` when you want a typed UUID value.
///
/// ## Example
///
/// ```gleam
/// use id <- sextant.field("id", sextant.uuid())
/// sextant.success(User(id:, ...))
/// ```
pub fn uuid() -> JsonSchema(Uuid) {
  let zero_uuid = uuid.v4()
  JsonSchema(
    schema: StringSchema(
      StringConstraints(..empty_string_constraints, format: Some(Uuid)),
      empty_metadata,
    ),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.string) |> result.replace_error(Nil) {
        Ok(s) ->
          case uuid.from_string(s) {
            Ok(id) -> #(id, [])
            Error(_) -> #(zero_uuid, [
              ConstraintError(
                StringViolation(InvalidFormat(format: "uuid", actual: s)),
                [],
              ),
            ])
          }
        Error(_) -> #(zero_uuid, [
          TypeError("String", dynamic.classify(data), []),
        ])
      }
    },
    zero: zero_uuid,
  )
}

/// Create a schema for RFC 3339 timestamps that decodes to `gleam/time/timestamp.Timestamp`.
///
/// This validates and parses the string as an RFC 3339 datetime, returning
/// the proper `Timestamp` type from `gleam_time`. Use this instead of
/// `string() |> format(DateTime)` when you want a typed timestamp value.
///
/// ## Example
///
/// ```gleam
/// use created_at <- sextant.field("created_at", sextant.timestamp())
/// sextant.success(Event(created_at:, ...))
/// ```
pub fn timestamp() -> JsonSchema(Timestamp) {
  JsonSchema(
    schema: StringSchema(
      StringConstraints(..empty_string_constraints, format: Some(DateTime)),
      empty_metadata,
    ),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.string) |> result.replace_error(Nil) {
        Ok(s) ->
          case timestamp.parse_rfc3339(s) {
            Ok(ts) -> #(ts, [])
            Error(_) -> #(timestamp.unix_epoch, [
              ConstraintError(
                StringViolation(InvalidFormat(format: "date-time", actual: s)),
                [],
              ),
            ])
          }
        Error(_) -> #(timestamp.unix_epoch, [
          TypeError("String", dynamic.classify(data), []),
        ])
      }
    },
    zero: timestamp.unix_epoch,
  )
}

/// Create a schema for URIs that decodes to `gleam/uri.Uri`.
///
/// This validates and parses the string as a URI, returning the proper
/// `Uri` type from `gleam_stdlib`. Use this instead of
/// `string() |> format(Uri)` when you want a typed URI value.
///
/// ## Example
///
/// ```gleam
/// use website <- sextant.optional_field("website", sextant.uri())
/// sextant.success(Profile(website:, ...))
/// ```
pub fn uri() -> JsonSchema(uri.Uri) {
  JsonSchema(
    schema: StringSchema(
      StringConstraints(..empty_string_constraints, format: Some(Uri)),
      empty_metadata,
    ),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.string) |> result.replace_error(Nil) {
        Ok(s) ->
          case uri.parse(s) {
            Ok(u) ->
              // Must have a scheme to be a valid absolute URI
              case u.scheme {
                Some(_) -> #(u, [])
                None -> #(uri.empty, [
                  ConstraintError(
                    StringViolation(InvalidFormat(format: "uri", actual: s)),
                    [],
                  ),
                ])
              }
            Error(_) -> #(uri.empty, [
              ConstraintError(
                StringViolation(InvalidFormat(format: "uri", actual: s)),
                [],
              ),
            ])
          }
        Error(_) -> #(uri.empty, [
          TypeError("String", dynamic.classify(data), []),
        ])
      }
    },
    zero: uri.empty,
  )
}

// ---------------------------------------------------------------------------
// Object Field Combinators
// ---------------------------------------------------------------------------

/// Finalise a schema with a successfully constructed value.
///
/// This is the terminal function in a use-chain for object schemas.
///
/// ## Example
///
/// ```gleam
/// use name <- sextant.field("name", sextant.string())
/// sextant.success(User(name:))
/// ```
pub fn success(value: a) -> JsonSchema(a) {
  JsonSchema(
    schema: ObjectSchema(
      properties: [],
      required: [],
      additional_properties: False,
      meta: empty_metadata,
    ),
    decoder: fn(_, _) { #(value, []) },
    zero: value,
  )
}

/// Allow additional properties in the generated JSON Schema.
///
/// By default, object schemas set `additionalProperties: false` to enforce
/// strict validation. Use this combinator to allow extra properties that
/// aren't defined in the schema.
///
/// Note: This only affects the generated JSON Schema document. Sextant's
/// decoder always ignores additional properties during validation.
///
/// ## Example
///
/// ```gleam
/// fn user_schema() -> sextant.JsonSchema(User) {
///   use name <- sextant.field("name", sextant.string())
///   sextant.success(User(name:))
/// }
/// |> sextant.additional_properties(True)
/// ```
pub fn additional_properties(
  schema: JsonSchema(a),
  allow: Bool,
) -> JsonSchema(a) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    ObjectSchema(properties, required, _, meta) ->
      ObjectSchema(properties, required, allow, meta)
    _ -> def
  }
  JsonSchema(schema: new_def, decoder:, zero:)
}

/// Extract a required field from an object.
///
/// The field must be present in the JSON object, otherwise a `MissingField`
/// error is returned.
///
/// ## Example
///
/// ```gleam
/// use name <- sextant.field("name", sextant.string())
/// use age <- sextant.field("age", sextant.integer())
/// sextant.success(User(name:, age:))
/// ```
pub fn field(
  name: String,
  field_schema: JsonSchema(a),
  next: fn(a) -> JsonSchema(b),
) -> JsonSchema(b) {
  let next_schema = next(field_schema.zero)
  JsonSchema(
    schema: build_object_schema(name, field_schema, next_schema),
    decoder: fn(data, opts) {
      let field_result = get_field(data, name)
      case field_result {
        Ok(Some(field_data)) -> {
          let #(value, field_errors) = field_schema.decoder(field_data, opts)
          let field_errors = prepend_path(field_errors, name)
          let next_schema = next(value)
          let #(final_value, next_errors) = next_schema.decoder(data, opts)
          #(final_value, list.append(field_errors, next_errors))
        }
        Ok(None) -> {
          // Field is missing - use zero value to continue building result
          let next_schema = next(field_schema.zero)
          let #(final_value, next_errors) = next_schema.decoder(data, opts)
          #(final_value, [MissingField(name, []), ..next_errors])
        }
        Error(_) -> {
          // Not an object
          let next_schema = next(field_schema.zero)
          let #(final_value, _) = next_schema.decoder(data, opts)
          #(final_value, [
            TypeError("Object", dynamic.classify(data), []),
          ])
        }
      }
    },
    zero: next_schema.zero,
  )
}

/// Extract an optional field from an object.
///
/// Returns `Some(value)` if the field is present, `None` if missing.
///
/// ## Example
///
/// ```gleam
/// use name <- sextant.field("name", sextant.string())
/// use email <- sextant.optional_field("email", sextant.string())
/// sextant.success(User(name:, email:))
/// ```
pub fn optional_field(
  name: String,
  field_schema: JsonSchema(a),
  next: fn(Option(a)) -> JsonSchema(b),
) -> JsonSchema(b) {
  let next_schema = next(None)
  JsonSchema(
    schema: build_object_schema_optional(name, field_schema, next_schema),
    decoder: fn(data, opts) {
      let field_result = get_field(data, name)
      case field_result {
        Ok(Some(field_data)) -> {
          case is_null(field_data) {
            True -> {
              let next_schema = next(None)
              next_schema.decoder(data, opts)
            }
            False -> {
              let #(value, field_errors) =
                field_schema.decoder(field_data, opts)
              let field_errors = prepend_path(field_errors, name)
              let next_schema = next(Some(value))
              let #(final_value, next_errors) = next_schema.decoder(data, opts)
              #(final_value, list.append(field_errors, next_errors))
            }
          }
        }
        Ok(None) -> {
          // Field is missing - that's ok for optional
          let next_schema = next(None)
          next_schema.decoder(data, opts)
        }
        Error(_) -> {
          // Not an object
          let next_schema = next(None)
          let #(final_value, _) = next_schema.decoder(data, opts)
          #(final_value, [
            TypeError("Object", dynamic.classify(data), []),
          ])
        }
      }
    },
    zero: next_schema.zero,
  )
}

// ---------------------------------------------------------------------------
// Compound Types
// ---------------------------------------------------------------------------

/// Create a schema for JSON arrays.
///
/// ## Example
///
/// ```gleam
/// let tags_schema = sextant.array(of: sextant.string())
/// ```
pub fn array(of inner: JsonSchema(a)) -> JsonSchema(List(a)) {
  JsonSchema(
    schema: ArraySchema(inner.schema, empty_array_constraints, empty_metadata),
    decoder: fn(data, opts) { decode_array(data, inner, opts) },
    zero: [],
  )
}

/// Create a schema for a fixed-length array with 2 elements of different types.
///
/// This generates a JSON Schema with `prefixItems` and exact length constraints.
///
/// ## Example
///
/// ```gleam
/// // A point as [x, y] coordinates
/// let point_schema = sextant.tuple2(sextant.number(), sextant.number())
///
/// // A key-value pair as [string, int]
/// let pair_schema = sextant.tuple2(sextant.string(), sextant.integer())
/// ```
pub fn tuple2(
  first: JsonSchema(a),
  second: JsonSchema(b),
) -> JsonSchema(#(a, b)) {
  JsonSchema(
    schema: TupleSchema([first.schema, second.schema], empty_metadata),
    decoder: fn(data, opts) { decode_tuple2(data, first, second, opts) },
    zero: #(first.zero, second.zero),
  )
}

/// Create a schema for a fixed-length array with 3 elements of different types.
///
/// This generates a JSON Schema with `prefixItems` and exact length constraints.
///
/// ## Example
///
/// ```gleam
/// // RGB colour as [r, g, b]
/// let rgb_schema = sextant.tuple3(
///   sextant.integer() |> sextant.int_min(0) |> sextant.int_max(255),
///   sextant.integer() |> sextant.int_min(0) |> sextant.int_max(255),
///   sextant.integer() |> sextant.int_min(0) |> sextant.int_max(255),
/// )
/// ```
pub fn tuple3(
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
) -> JsonSchema(#(a, b, c)) {
  JsonSchema(
    schema: TupleSchema(
      [first.schema, second.schema, third.schema],
      empty_metadata,
    ),
    decoder: fn(data, opts) { decode_tuple3(data, first, second, third, opts) },
    zero: #(first.zero, second.zero, third.zero),
  )
}

/// Create a schema for a fixed-length array with 4 elements of different types.
///
/// This generates a JSON Schema with `prefixItems` and exact length constraints.
///
/// ## Example
///
/// ```gleam
/// // RGBA colour as [r, g, b, a]
/// let rgba_schema = sextant.tuple4(
///   sextant.integer(),
///   sextant.integer(),
///   sextant.integer(),
///   sextant.number(),
/// )
/// ```
pub fn tuple4(
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
) -> JsonSchema(#(a, b, c, d)) {
  JsonSchema(
    schema: TupleSchema(
      [first.schema, second.schema, third.schema, fourth.schema],
      empty_metadata,
    ),
    decoder: fn(data, opts) {
      decode_tuple4(data, first, second, third, fourth, opts)
    },
    zero: #(first.zero, second.zero, third.zero, fourth.zero),
  )
}

/// Create a schema for a fixed-length array with 5 elements of different types.
///
/// This generates a JSON Schema with `prefixItems` and exact length constraints.
pub fn tuple5(
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
  fifth: JsonSchema(e),
) -> JsonSchema(#(a, b, c, d, e)) {
  JsonSchema(
    schema: TupleSchema(
      [first.schema, second.schema, third.schema, fourth.schema, fifth.schema],
      empty_metadata,
    ),
    decoder: fn(data, opts) {
      decode_tuple5(data, first, second, third, fourth, fifth, opts)
    },
    zero: #(first.zero, second.zero, third.zero, fourth.zero, fifth.zero),
  )
}

/// Create a schema for a fixed-length array with 6 elements of different types.
///
/// This generates a JSON Schema with `prefixItems` and exact length constraints.
pub fn tuple6(
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
  fifth: JsonSchema(e),
  sixth: JsonSchema(f),
) -> JsonSchema(#(a, b, c, d, e, f)) {
  JsonSchema(
    schema: TupleSchema(
      [
        first.schema,
        second.schema,
        third.schema,
        fourth.schema,
        fifth.schema,
        sixth.schema,
      ],
      empty_metadata,
    ),
    decoder: fn(data, opts) {
      decode_tuple6(data, first, second, third, fourth, fifth, sixth, opts)
    },
    zero: #(
      first.zero,
      second.zero,
      third.zero,
      fourth.zero,
      fifth.zero,
      sixth.zero,
    ),
  )
}

/// Create a schema that allows null values.
///
/// Returns `Some(value)` if the value is present and valid, `None` if null.
///
/// ## Example
///
/// ```gleam
/// let optional_name = sextant.optional(sextant.string())
/// ```
pub fn optional(inner: JsonSchema(a)) -> JsonSchema(Option(a)) {
  JsonSchema(
    schema: NullableSchema(inner.schema, empty_metadata),
    decoder: fn(data, opts) {
      case is_null(data) {
        True -> #(None, [])
        False -> {
          let #(value, errors) = inner.decoder(data, opts)
          #(Some(value), errors)
        }
      }
    },
    zero: None,
  )
}

/// Create a schema for JSON objects with arbitrary string keys.
///
/// ## Example
///
/// ```gleam
/// let scores_schema = sextant.dict(sextant.integer())
/// // Validates: {"alice": 100, "bob": 85}
/// ```
pub fn dict(value_schema: JsonSchema(v)) -> JsonSchema(Dict(String, v)) {
  JsonSchema(
    schema: DictSchema(value_schema.schema, empty_metadata),
    decoder: fn(data, opts) {
      case
        decode.run(data, decode.dict(decode.string, decode.dynamic))
        |> result.replace_error(Nil)
      {
        Ok(d) -> {
          dict.fold(d, #(dict.new(), []), fn(acc, key, value) {
            let #(result_dict, errors) = acc
            let #(decoded_value, value_errors) =
              value_schema.decoder(value, opts)
            let value_errors = prepend_path(value_errors, key)
            #(
              dict.insert(result_dict, key, decoded_value),
              list.append(errors, value_errors),
            )
          })
        }
        Error(_) -> #(dict.new(), [
          TypeError("Object", dynamic.classify(data), []),
        ])
      }
    },
    zero: dict.new(),
  )
}

// ---------------------------------------------------------------------------
// Combinators
// ---------------------------------------------------------------------------

/// Create a schema for a string enum that maps to Gleam values.
///
/// ## Example
///
/// ```gleam
/// type Role {
///   Admin
///   Member
///   Guest
/// }
///
/// let role_schema = sextant.enum(#("admin", Admin), [
///   #("member", Member),
///   #("guest", Guest),
/// ])
/// ```
pub fn enum(first: #(String, a), rest: List(#(String, a))) -> JsonSchema(a) {
  let variants = [first, ..rest]
  let enum_values = list.map(variants, fn(v) { v.0 })
  let #(_, zero_val) = first

  JsonSchema(
    schema: EnumSchema(enum_values, empty_metadata),
    decoder: fn(data, _opts) {
      case decode.run(data, decode.string) |> result.replace_error(Nil) {
        Ok(str) -> {
          case list.find(variants, fn(v) { v.0 == str }) {
            Ok(#(_, value)) -> #(value, [])
            Error(_) -> #(zero_val, [
              UnknownVariant(str, enum_values, []),
            ])
          }
        }
        Error(_) -> #(zero_val, [
          TypeError("String", dynamic.classify(data), []),
        ])
      }
    },
    zero: zero_val,
  )
}

/// Create a schema where exactly one of the variants must match.
///
/// Note: At runtime, `one_of` and `any_of` have identical validation behaviour -
/// the first matching schema is used. The distinction only affects the generated
/// JSON Schema output (`oneOf` vs `anyOf`).
///
/// ## Example
///
/// ```gleam
/// let string_or_int = sextant.one_of(
///   sextant.string() |> sextant.map(StringValue),
///   [sextant.integer() |> sextant.map(IntValue)],
/// )
/// ```
pub fn one_of(first: JsonSchema(a), rest: List(JsonSchema(a))) -> JsonSchema(a) {
  let all_schemas = [first, ..rest]
  let schema_defs = list.map(all_schemas, fn(s) { s.schema })

  JsonSchema(
    schema: OneOfSchema(schema_defs, empty_metadata),
    decoder: fn(data, opts) {
      try_decoders(data, opts, all_schemas, first, "OneOf")
    },
    zero: first.zero,
  )
}

/// Create a schema where at least one of the variants must match.
///
/// Note: At runtime, `one_of` and `any_of` have identical validation behaviour -
/// the first matching schema is used. The distinction only affects the generated
/// JSON Schema output (`oneOf` vs `anyOf`).
///
/// ## Example
///
/// ```gleam
/// let flexible_schema = sextant.any_of(
///   sextant.string() |> sextant.map(process_string),
///   [sextant.integer() |> sextant.map(process_int)],
/// )
/// ```
pub fn any_of(first: JsonSchema(a), rest: List(JsonSchema(a))) -> JsonSchema(a) {
  let all_schemas = [first, ..rest]
  let schema_defs = list.map(all_schemas, fn(s) { s.schema })

  JsonSchema(
    schema: AnyOfSchema(schema_defs, empty_metadata),
    decoder: fn(data, opts) {
      try_decoders(data, opts, all_schemas, first, "AnyOf")
    },
    zero: first.zero,
  )
}

/// Transform the decoded value using a function.
///
/// ## Example
///
/// ```gleam
/// let uppercase_string = sextant.string() |> sextant.map(string.uppercase)
/// ```
pub fn map(schema: JsonSchema(a), transform: fn(a) -> b) -> JsonSchema(b) {
  JsonSchema(
    schema: schema.schema,
    decoder: fn(data, opts) {
      let #(value, errors) = schema.decoder(data, opts)
      #(transform(value), errors)
    },
    zero: transform(schema.zero),
  )
}

/// Transform the decoded value using a fallible function.
///
/// If the transform returns `Error`, it's converted to a `ConstraintError`
/// using the provided error message. The `default` value is used as the
/// zero value for schema extraction and as the fallback when the transform fails.
///
/// Use this for validations that can't be expressed with built-in constraints,
/// such as parsing strings into custom types or cross-field validation.
///
/// ## Example
///
/// ```gleam
/// pub type Slug { Slug(String) }
///
/// fn parse_slug(s: String) -> Result(Slug, String) {
///   let is_valid = string.length(s) > 0
///     && string.lowercase(s) == s
///     && !string.contains(s, " ")
///   case is_valid {
///     True -> Ok(Slug(s))
///     False -> Error("must be lowercase with no spaces")
///   }
/// }
///
/// let slug_schema = sextant.string()
///   |> sextant.try_map(parse_slug, default: Slug("default"))
/// ```
pub fn try_map(
  schema: JsonSchema(a),
  transform: fn(a) -> Result(b, String),
  default default: b,
) -> JsonSchema(b) {
  JsonSchema(
    schema: schema.schema,
    decoder: fn(data, opts) {
      let #(value, errors) = schema.decoder(data, opts)
      case has_type_error(errors) {
        True -> #(default, errors)
        False ->
          case transform(value) {
            Ok(transformed) -> #(transformed, errors)
            Error(msg) -> #(
              default,
              list.append(errors, [
                ConstraintError(CustomViolation(msg), []),
              ]),
            )
          }
      }
    },
    zero: default,
  )
}

/// Constrain a schema to accept only a specific constant value.
///
/// The `to_json` function converts the value to its JSON representation
/// for schema generation. For primitives, use the corresponding `json` function.
///
/// ## Example
///
/// ```gleam
/// let version_schema = sextant.string() |> sextant.const_value("v1", json.string)
/// let answer_schema = sextant.integer() |> sextant.const_value(42, json.int)
/// let enabled_schema = sextant.boolean() |> sextant.const_value(True, json.bool)
/// ```
pub fn const_value(
  schema: JsonSchema(a),
  value: a,
  to_json: fn(a) -> json.Json,
) -> JsonSchema(a) {
  let JsonSchema(_def, decoder, _zero) = schema
  JsonSchema(
    schema: ConstSchema(to_json(value), empty_metadata),
    decoder: fn(data, opts) {
      let #(decoded, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(decoded, errors)
        False ->
          case decoded == value {
            True -> #(decoded, errors)
            False -> #(
              value,
              list.append(errors, [
                ConstMismatch(
                  expected: string.inspect(value),
                  actual: string.inspect(decoded),
                  path: [],
                ),
              ]),
            )
          }
      }
    },
    zero: value,
  )
}

// ---------------------------------------------------------------------------
// String Constraints
// ---------------------------------------------------------------------------

/// Set minimum string length.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string() |> sextant.min_length(1)
/// ```
pub fn min_length(schema: JsonSchema(String), min: Int) -> JsonSchema(String) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    StringSchema(constraints, meta) ->
      StringSchema(
        StringConstraints(..constraints, min_length: Some(min)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let len = string.length(value)
          case len < min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  StringViolation(StringTooShort(min:, actual: len)),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
        }
      }
    },
    zero:,
  )
}

/// Set maximum string length.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string() |> sextant.max_length(100)
/// ```
pub fn max_length(schema: JsonSchema(String), max: Int) -> JsonSchema(String) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    StringSchema(constraints, meta) ->
      StringSchema(
        StringConstraints(..constraints, max_length: Some(max)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let len = string.length(value)
          case len > max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  StringViolation(StringTooLong(max:, actual: len)),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
        }
      }
    },
    zero:,
  )
}

/// Set a regex pattern the string must match.
///
/// If the pattern is not a valid regex, validation will return an
/// `InvalidPattern` constraint error.
///
/// ## Example
///
/// ```gleam
/// let slug_schema = sextant.string() |> sextant.pattern("^[a-z0-9-]+$")
/// ```
pub fn pattern(
  schema: JsonSchema(String),
  pattern_string: String,
) -> JsonSchema(String) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    StringSchema(constraints, meta) ->
      StringSchema(
        StringConstraints(..constraints, pattern: Some(pattern_string)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          case regexp.from_string(pattern_string) {
            Error(regexp.CompileError(error: err, byte_index: _)) -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  StringViolation(InvalidPattern(
                    pattern: pattern_string,
                    error: err,
                  )),
                  [],
                ),
              ]),
            )
            Ok(regex) ->
              case regexp.check(regex, value) {
                True -> #(value, errors)
                False -> #(
                  value,
                  list.append(errors, [
                    ConstraintError(
                      StringViolation(PatternMismatch(
                        pattern: pattern_string,
                        actual: value,
                      )),
                      [],
                    ),
                  ]),
                )
              }
          }
        }
      }
    },
    zero:,
  )
}

/// Set a string format constraint.
///
/// Format validation only runs when `Options.validate_formats` is `True`.
///
/// ## Example
///
/// ```gleam
/// let email_schema = sextant.string() |> sextant.format(sextant.Email)
/// ```
pub fn format(
  schema: JsonSchema(String),
  fmt: StringFormat,
) -> JsonSchema(String) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    StringSchema(constraints, meta) ->
      StringSchema(StringConstraints(..constraints, format: Some(fmt)), meta)
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors), opts.validate_formats {
        True, _ -> #(value, errors)
        False, True -> {
          case validate_format(value, fmt) {
            True -> #(value, errors)
            False -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  StringViolation(InvalidFormat(
                    format: string_format_to_string(fmt),
                    actual: value,
                  )),
                  [],
                ),
              ]),
            )
          }
        }
        False, False -> #(value, errors)
      }
    },
    zero:,
  )
}

// ---------------------------------------------------------------------------
// Integer Constraints
// ---------------------------------------------------------------------------

/// Set inclusive minimum value for integers.
///
/// ## Example
///
/// ```gleam
/// let age_schema = sextant.integer() |> sextant.int_min(0)
/// ```
pub fn int_min(schema: JsonSchema(Int), min: Int) -> JsonSchema(Int) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    IntegerSchema(constraints, meta) ->
      IntegerSchema(IntConstraints(..constraints, minimum: Some(min)), meta)
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value < min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooSmall(
                    minimum: int.to_float(min),
                    exclusive: False,
                    actual: int.to_float(value),
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set inclusive maximum value for integers.
///
/// ## Example
///
/// ```gleam
/// let age_schema = sextant.integer() |> sextant.int_max(150)
/// ```
pub fn int_max(schema: JsonSchema(Int), max: Int) -> JsonSchema(Int) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    IntegerSchema(constraints, meta) ->
      IntegerSchema(IntConstraints(..constraints, maximum: Some(max)), meta)
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value > max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooLarge(
                    maximum: int.to_float(max),
                    exclusive: False,
                    actual: int.to_float(value),
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set exclusive minimum value for integers.
///
/// ## Example
///
/// ```gleam
/// let positive_schema = sextant.integer() |> sextant.int_exclusive_min(0)
/// ```
pub fn int_exclusive_min(schema: JsonSchema(Int), min: Int) -> JsonSchema(Int) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    IntegerSchema(constraints, meta) ->
      IntegerSchema(
        IntConstraints(..constraints, exclusive_minimum: Some(min)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value <= min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooSmall(
                    minimum: int.to_float(min),
                    exclusive: True,
                    actual: int.to_float(value),
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set exclusive maximum value for integers.
///
/// ## Example
///
/// ```gleam
/// let under_100 = sextant.integer() |> sextant.int_exclusive_max(100)
/// ```
pub fn int_exclusive_max(schema: JsonSchema(Int), max: Int) -> JsonSchema(Int) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    IntegerSchema(constraints, meta) ->
      IntegerSchema(
        IntConstraints(..constraints, exclusive_maximum: Some(max)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value >= max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooLarge(
                    maximum: int.to_float(max),
                    exclusive: True,
                    actual: int.to_float(value),
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set that the integer must be a multiple of a given value.
///
/// Note: If `multiple` is 0, all values will be considered valid since
/// `x % 0 = 0` in Gleam.
///
/// ## Example
///
/// ```gleam
/// let even_schema = sextant.integer() |> sextant.int_multiple_of(2)
/// ```
pub fn int_multiple_of(
  schema: JsonSchema(Int),
  multiple: Int,
) -> JsonSchema(Int) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    IntegerSchema(constraints, meta) ->
      IntegerSchema(
        IntConstraints(..constraints, multiple_of: Some(multiple)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value % multiple == 0 {
            True -> #(value, errors)
            False -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NotMultipleOf(
                    multiple: int.to_float(multiple),
                    actual: int.to_float(value),
                  )),
                  [],
                ),
              ]),
            )
          }
      }
    },
    zero:,
  )
}

// ---------------------------------------------------------------------------
// Float Constraints
// ---------------------------------------------------------------------------

/// Set inclusive minimum value for floats.
///
/// ## Example
///
/// ```gleam
/// let price_schema = sextant.number() |> sextant.float_min(0.0)
/// ```
pub fn float_min(schema: JsonSchema(Float), min: Float) -> JsonSchema(Float) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    NumberSchema(constraints, meta) ->
      NumberSchema(FloatConstraints(..constraints, minimum: Some(min)), meta)
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value <. min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooSmall(
                    minimum: min,
                    exclusive: False,
                    actual: value,
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set inclusive maximum value for floats.
///
/// ## Example
///
/// ```gleam
/// let percentage_schema = sextant.number() |> sextant.float_max(100.0)
/// ```
pub fn float_max(schema: JsonSchema(Float), max: Float) -> JsonSchema(Float) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    NumberSchema(constraints, meta) ->
      NumberSchema(FloatConstraints(..constraints, maximum: Some(max)), meta)
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value >. max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooLarge(
                    maximum: max,
                    exclusive: False,
                    actual: value,
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set exclusive minimum value for floats.
///
/// ## Example
///
/// ```gleam
/// let positive_schema = sextant.number() |> sextant.float_exclusive_min(0.0)
/// ```
pub fn float_exclusive_min(
  schema: JsonSchema(Float),
  min: Float,
) -> JsonSchema(Float) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    NumberSchema(constraints, meta) ->
      NumberSchema(
        FloatConstraints(..constraints, exclusive_minimum: Some(min)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value <=. min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooSmall(
                    minimum: min,
                    exclusive: True,
                    actual: value,
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set exclusive maximum value for floats.
///
/// ## Example
///
/// ```gleam
/// let under_100 = sextant.number() |> sextant.float_exclusive_max(100.0)
/// ```
pub fn float_exclusive_max(
  schema: JsonSchema(Float),
  max: Float,
) -> JsonSchema(Float) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    NumberSchema(constraints, meta) ->
      NumberSchema(
        FloatConstraints(..constraints, exclusive_maximum: Some(max)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False ->
          case value >=. max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NumberTooLarge(
                    maximum: max,
                    exclusive: True,
                    actual: value,
                  )),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
      }
    },
    zero:,
  )
}

/// Set that the float must be a multiple of a given value.
///
/// Note: Due to floating-point precision, a small tolerance (1e-7) is used
/// when checking the remainder. If `multiple` is 0.0, all values will be
/// considered valid since `x %.. 0.0 = 0.0` in Gleam.
///
/// ## Example
///
/// ```gleam
/// let quarter_schema = sextant.number() |> sextant.float_multiple_of(0.25)
/// ```
pub fn float_multiple_of(
  schema: JsonSchema(Float),
  multiple: Float,
) -> JsonSchema(Float) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    NumberSchema(constraints, meta) ->
      NumberSchema(
        FloatConstraints(..constraints, multiple_of: Some(multiple)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let remainder = float_modulo(value, multiple)
          case
            remainder == 0.0 || float.absolute_value(remainder) <. 0.0000001
          {
            True -> #(value, errors)
            False -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  NumberViolation(NotMultipleOf(multiple:, actual: value)),
                  [],
                ),
              ]),
            )
          }
        }
      }
    },
    zero:,
  )
}

// ---------------------------------------------------------------------------
// Array Constraints
// ---------------------------------------------------------------------------

/// Set minimum number of items in an array.
///
/// ## Example
///
/// ```gleam
/// let tags_schema = sextant.array(sextant.string()) |> sextant.min_items(1)
/// ```
pub fn min_items(schema: JsonSchema(List(a)), min: Int) -> JsonSchema(List(a)) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    ArraySchema(items, constraints, meta) ->
      ArraySchema(
        items,
        ArrayConstraints(..constraints, min_items: Some(min)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let len = list.length(value)
          case len < min {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  ArrayViolation(ArrayTooShort(min:, actual: len)),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
        }
      }
    },
    zero:,
  )
}

/// Set maximum number of items in an array.
///
/// ## Example
///
/// ```gleam
/// let tags_schema = sextant.array(sextant.string()) |> sextant.max_items(10)
/// ```
pub fn max_items(schema: JsonSchema(List(a)), max: Int) -> JsonSchema(List(a)) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    ArraySchema(items, constraints, meta) ->
      ArraySchema(
        items,
        ArrayConstraints(..constraints, max_items: Some(max)),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let len = list.length(value)
          case len > max {
            True -> #(
              value,
              list.append(errors, [
                ConstraintError(
                  ArrayViolation(ArrayTooLong(max:, actual: len)),
                  [],
                ),
              ]),
            )
            False -> #(value, errors)
          }
        }
      }
    },
    zero:,
  )
}

/// Require all array items to be unique.
///
/// ## Example
///
/// ```gleam
/// let unique_tags = sextant.array(sextant.string()) |> sextant.unique_items()
/// ```
pub fn unique_items(schema: JsonSchema(List(a))) -> JsonSchema(List(a)) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    ArraySchema(items, constraints, meta) ->
      ArraySchema(
        items,
        ArrayConstraints(..constraints, unique_items: True),
        meta,
      )
    _ -> def
  }
  JsonSchema(
    schema: new_def,
    decoder: fn(data, opts) {
      let #(value, errors) = decoder(data, opts)
      case has_type_error(errors) {
        True -> #(value, errors)
        False -> {
          let unique_count = list.unique(value) |> list.length
          let total_count = list.length(value)
          case unique_count == total_count {
            True -> #(value, errors)
            False -> #(
              value,
              list.append(errors, [
                ConstraintError(ArrayViolation(ItemsNotUnique), []),
              ]),
            )
          }
        }
      }
    },
    zero:,
  )
}

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

/// Add a description to the schema.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string() |> sextant.describe("The user's name")
/// ```
pub fn describe(schema: JsonSchema(a), description: String) -> JsonSchema(a) {
  update_metadata(schema, fn(m) {
    Metadata(..m, description: Some(description))
  })
}

/// Add a title to the schema.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string() |> sextant.title("User Name")
/// ```
pub fn title(schema: JsonSchema(a), title_text: String) -> JsonSchema(a) {
  update_metadata(schema, fn(m) { Metadata(..m, title: Some(title_text)) })
}

/// Add examples to the schema.
///
/// ## Example
///
/// ```gleam
/// let name_schema = sextant.string()
///   |> sextant.examples([json.string("Alice"), json.string("Bob")])
/// ```
pub fn examples(schema: JsonSchema(a), ex: List(json.Json)) -> JsonSchema(a) {
  update_metadata(schema, fn(m) { Metadata(..m, examples: ex) })
}

/// Add a default value to the schema.
///
/// ## Example
///
/// ```gleam
/// let count_schema = sextant.integer()
///   |> sextant.default(json.int(0))
/// ```
pub fn default(schema: JsonSchema(a), def: json.Json) -> JsonSchema(a) {
  update_metadata(schema, fn(m) { Metadata(..m, default: Some(def)) })
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

/// Validate and decode dynamic data against a schema.
///
/// ## Example
///
/// ```gleam
/// case sextant.run(data, user_schema()) {
///   Ok(user) -> // use the decoded user
///   Error(errors) -> // handle validation errors
/// }
/// ```
pub fn run(
  data: Dynamic,
  schema: JsonSchema(a),
) -> Result(a, List(ValidationError)) {
  run_with_options(data, schema, default_options)
}

/// Validate and decode dynamic data with custom options.
///
/// ## Example
///
/// ```gleam
/// let opts = sextant.Options(validate_formats: True)
/// case sextant.run_with_options(data, email_schema, opts) {
///   Ok(email) -> // email format was validated
///   Error(errors) -> // handle validation errors
/// }
/// ```
pub fn run_with_options(
  data: Dynamic,
  schema: JsonSchema(a),
  options: Options,
) -> Result(a, List(ValidationError)) {
  let #(value, errors) = schema.decoder(data, options)
  case errors {
    [] -> Ok(value)
    _ -> Error(errors)
  }
}

/// Generate a JSON Schema 2020-12 document.
///
/// ## Example
///
/// ```gleam
/// let schema_json = sextant.to_json(user_schema())
/// ```
pub fn to_json(schema: JsonSchema(a)) -> json.Json {
  let base_fields = schema_definition_to_fields(schema.schema)
  json.object([
    #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
    ..base_fields
  ])
}

// ---------------------------------------------------------------------------
// Internal: JSON Schema Encoding
// ---------------------------------------------------------------------------

fn schema_definition_to_json(def: SchemaDefinition) -> json.Json {
  json.object(schema_definition_to_fields(def))
}

fn schema_definition_to_fields(
  def: SchemaDefinition,
) -> List(#(String, json.Json)) {
  case def {
    StringSchema(constraints, meta) -> {
      let base = [#("type", json.string("string"))]
      let with_constraints = add_string_constraints(base, constraints)
      add_metadata(with_constraints, meta)
    }

    IntegerSchema(constraints, meta) -> {
      let base = [#("type", json.string("integer"))]
      let with_constraints = add_int_constraints(base, constraints)
      add_metadata(with_constraints, meta)
    }

    NumberSchema(constraints, meta) -> {
      let base = [#("type", json.string("number"))]
      let with_constraints = add_float_constraints(base, constraints)
      add_metadata(with_constraints, meta)
    }

    BooleanSchema(meta) -> {
      let base = [#("type", json.string("boolean"))]
      add_metadata(base, meta)
    }

    NullSchema(meta) -> {
      let base = [#("type", json.string("null"))]
      add_metadata(base, meta)
    }

    ArraySchema(items, constraints, meta) -> {
      let base = [
        #("type", json.string("array")),
        #("items", schema_definition_to_json(items)),
      ]
      let with_constraints = add_array_constraints(base, constraints)
      add_metadata(with_constraints, meta)
    }

    ObjectSchema(properties, required, additional_properties, meta) -> {
      let props =
        properties
        |> list.map(fn(p) { #(p.name, schema_definition_to_json(p.schema)) })
        |> json.object

      let base = case additional_properties {
        True -> [#("type", json.string("object")), #("properties", props)]
        False -> [
          #("type", json.string("object")),
          #("properties", props),
          #("additionalProperties", json.bool(False)),
        ]
      }

      let with_required = case required {
        [] -> base
        _ -> [#("required", json.array(required, json.string)), ..base]
      }

      add_metadata(with_required, meta)
    }

    DictSchema(values, meta) -> {
      let base = [
        #("type", json.string("object")),
        #("additionalProperties", schema_definition_to_json(values)),
      ]
      add_metadata(base, meta)
    }

    NullableSchema(inner, meta) -> {
      let base = [
        #(
          "oneOf",
          json.array(
            [NullSchema(empty_metadata), inner],
            schema_definition_to_json,
          ),
        ),
      ]
      add_metadata(base, meta)
    }

    OneOfSchema(variants, meta) -> {
      let base = [
        #("oneOf", json.array(variants, schema_definition_to_json)),
      ]
      add_metadata(base, meta)
    }

    AnyOfSchema(variants, meta) -> {
      let base = [
        #("anyOf", json.array(variants, schema_definition_to_json)),
      ]
      add_metadata(base, meta)
    }

    EnumSchema(values, meta) -> {
      let base = [
        #("type", json.string("string")),
        #("enum", json.array(values, json.string)),
      ]
      add_metadata(base, meta)
    }

    ConstSchema(value, meta) -> {
      let base = [#("const", value)]
      add_metadata(base, meta)
    }

    TupleSchema(items, meta) -> {
      let base = [
        #("type", json.string("array")),
        #("prefixItems", json.array(items, schema_definition_to_json)),
        #("items", json.bool(False)),
        #("minItems", json.int(list.length(items))),
        #("maxItems", json.int(list.length(items))),
      ]
      add_metadata(base, meta)
    }
  }
}

fn add_string_constraints(
  fields: List(#(String, json.Json)),
  constraints: StringConstraints,
) -> List(#(String, json.Json)) {
  fields
  |> add_optional_int("minLength", constraints.min_length)
  |> add_optional_int("maxLength", constraints.max_length)
  |> add_optional_string("pattern", constraints.pattern)
  |> add_optional_format(constraints.format)
}

fn add_int_constraints(
  fields: List(#(String, json.Json)),
  constraints: IntConstraints,
) -> List(#(String, json.Json)) {
  fields
  |> add_optional_int("minimum", constraints.minimum)
  |> add_optional_int("maximum", constraints.maximum)
  |> add_optional_int("exclusiveMinimum", constraints.exclusive_minimum)
  |> add_optional_int("exclusiveMaximum", constraints.exclusive_maximum)
  |> add_optional_int("multipleOf", constraints.multiple_of)
}

fn add_float_constraints(
  fields: List(#(String, json.Json)),
  constraints: FloatConstraints,
) -> List(#(String, json.Json)) {
  fields
  |> add_optional_float("minimum", constraints.minimum)
  |> add_optional_float("maximum", constraints.maximum)
  |> add_optional_float("exclusiveMinimum", constraints.exclusive_minimum)
  |> add_optional_float("exclusiveMaximum", constraints.exclusive_maximum)
  |> add_optional_float("multipleOf", constraints.multiple_of)
}

fn add_array_constraints(
  fields: List(#(String, json.Json)),
  constraints: ArrayConstraints,
) -> List(#(String, json.Json)) {
  let fields =
    fields
    |> add_optional_int("minItems", constraints.min_items)
    |> add_optional_int("maxItems", constraints.max_items)

  case constraints.unique_items {
    True -> [#("uniqueItems", json.bool(True)), ..fields]
    False -> fields
  }
}

fn add_metadata(
  fields: List(#(String, json.Json)),
  meta: Metadata,
) -> List(#(String, json.Json)) {
  fields
  |> add_optional_string("title", meta.title)
  |> add_optional_string("description", meta.description)
  |> add_optional_json("default", meta.default)
  |> add_examples(meta.examples)
}

fn add_examples(
  fields: List(#(String, json.Json)),
  examples: List(json.Json),
) -> List(#(String, json.Json)) {
  case examples {
    [] -> fields
    _ -> [#("examples", json.array(examples, fn(x) { x })), ..fields]
  }
}

fn add_optional_int(
  fields: List(#(String, json.Json)),
  name: String,
  value: Option(Int),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> [#(name, json.int(v)), ..fields]
    None -> fields
  }
}

fn add_optional_float(
  fields: List(#(String, json.Json)),
  name: String,
  value: Option(Float),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> [#(name, json.float(v)), ..fields]
    None -> fields
  }
}

fn add_optional_string(
  fields: List(#(String, json.Json)),
  name: String,
  value: Option(String),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> [#(name, json.string(v)), ..fields]
    None -> fields
  }
}

fn add_optional_json(
  fields: List(#(String, json.Json)),
  name: String,
  value: Option(json.Json),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> [#(name, v), ..fields]
    None -> fields
  }
}

fn add_optional_format(
  fields: List(#(String, json.Json)),
  fmt: Option(StringFormat),
) -> List(#(String, json.Json)) {
  case fmt {
    Some(f) -> [#("format", json.string(string_format_to_string(f))), ..fields]
    None -> fields
  }
}

// ---------------------------------------------------------------------------
// Internal: Decoding Helpers
// ---------------------------------------------------------------------------

fn decode_array(
  data: Dynamic,
  inner: JsonSchema(a),
  opts: Options,
) -> #(List(a), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic))
    |> result.replace_error(Nil)
  {
    Ok(items) -> {
      let #(values, errors) =
        list.index_fold(items, #([], []), fn(acc, item, index) {
          let #(values, errors) = acc
          let #(value, item_errors) = inner.decoder(item, opts)
          let item_errors = prepend_path(item_errors, int.to_string(index))
          #([value, ..values], list.append(errors, item_errors))
        })
      #(list.reverse(values), errors)
    }
    Error(_) -> #([], [
      TypeError("Array", dynamic.classify(data), []),
    ])
  }
}

fn decode_tuple2(
  data: Dynamic,
  first: JsonSchema(a),
  second: JsonSchema(b),
  opts: Options,
) -> #(#(a, b), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  {
    Ok(items) ->
      case items {
        [item0, item1] -> {
          let #(v0, e0) = first.decoder(item0, opts)
          let e0 = prepend_path(e0, "0")
          let #(v1, e1) = second.decoder(item1, opts)
          let e1 = prepend_path(e1, "1")
          #(#(v0, v1), list.append(e0, e1))
        }
        _ -> #(#(first.zero, second.zero), [
          TypeError(
            "Tuple[2]",
            "Array[" <> int.to_string(list.length(items)) <> "]",
            [],
          ),
        ])
      }
    Error(_) -> #(#(first.zero, second.zero), [
      TypeError("Tuple[2]", dynamic.classify(data), []),
    ])
  }
}

fn decode_tuple3(
  data: Dynamic,
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  opts: Options,
) -> #(#(a, b, c), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  {
    Ok(items) ->
      case items {
        [item0, item1, item2] -> {
          let #(v0, e0) = first.decoder(item0, opts)
          let e0 = prepend_path(e0, "0")
          let #(v1, e1) = second.decoder(item1, opts)
          let e1 = prepend_path(e1, "1")
          let #(v2, e2) = third.decoder(item2, opts)
          let e2 = prepend_path(e2, "2")
          #(#(v0, v1, v2), list.flatten([e0, e1, e2]))
        }
        _ -> #(#(first.zero, second.zero, third.zero), [
          TypeError(
            "Tuple[3]",
            "Array[" <> int.to_string(list.length(items)) <> "]",
            [],
          ),
        ])
      }
    Error(_) -> #(#(first.zero, second.zero, third.zero), [
      TypeError("Tuple[3]", dynamic.classify(data), []),
    ])
  }
}

fn decode_tuple4(
  data: Dynamic,
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
  opts: Options,
) -> #(#(a, b, c, d), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  {
    Ok(items) ->
      case items {
        [item0, item1, item2, item3] -> {
          let #(v0, e0) = first.decoder(item0, opts)
          let e0 = prepend_path(e0, "0")
          let #(v1, e1) = second.decoder(item1, opts)
          let e1 = prepend_path(e1, "1")
          let #(v2, e2) = third.decoder(item2, opts)
          let e2 = prepend_path(e2, "2")
          let #(v3, e3) = fourth.decoder(item3, opts)
          let e3 = prepend_path(e3, "3")
          #(#(v0, v1, v2, v3), list.flatten([e0, e1, e2, e3]))
        }
        _ -> #(#(first.zero, second.zero, third.zero, fourth.zero), [
          TypeError(
            "Tuple[4]",
            "Array[" <> int.to_string(list.length(items)) <> "]",
            [],
          ),
        ])
      }
    Error(_) -> #(#(first.zero, second.zero, third.zero, fourth.zero), [
      TypeError("Tuple[4]", dynamic.classify(data), []),
    ])
  }
}

fn decode_tuple5(
  data: Dynamic,
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
  fifth: JsonSchema(e),
  opts: Options,
) -> #(#(a, b, c, d, e), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  {
    Ok(items) ->
      case items {
        [item0, item1, item2, item3, item4] -> {
          let #(v0, e0) = first.decoder(item0, opts)
          let e0 = prepend_path(e0, "0")
          let #(v1, e1) = second.decoder(item1, opts)
          let e1 = prepend_path(e1, "1")
          let #(v2, e2) = third.decoder(item2, opts)
          let e2 = prepend_path(e2, "2")
          let #(v3, e3) = fourth.decoder(item3, opts)
          let e3 = prepend_path(e3, "3")
          let #(v4, e4) = fifth.decoder(item4, opts)
          let e4 = prepend_path(e4, "4")
          #(#(v0, v1, v2, v3, v4), list.flatten([e0, e1, e2, e3, e4]))
        }
        _ -> #(#(first.zero, second.zero, third.zero, fourth.zero, fifth.zero), [
          TypeError(
            "Tuple[5]",
            "Array[" <> int.to_string(list.length(items)) <> "]",
            [],
          ),
        ])
      }
    Error(_) -> #(
      #(first.zero, second.zero, third.zero, fourth.zero, fifth.zero),
      [
        TypeError("Tuple[5]", dynamic.classify(data), []),
      ],
    )
  }
}

fn decode_tuple6(
  data: Dynamic,
  first: JsonSchema(a),
  second: JsonSchema(b),
  third: JsonSchema(c),
  fourth: JsonSchema(d),
  fifth: JsonSchema(e),
  sixth: JsonSchema(f),
  opts: Options,
) -> #(#(a, b, c, d, e, f), List(ValidationError)) {
  case
    decode.run(data, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  {
    Ok(items) ->
      case items {
        [item0, item1, item2, item3, item4, item5] -> {
          let #(v0, e0) = first.decoder(item0, opts)
          let e0 = prepend_path(e0, "0")
          let #(v1, e1) = second.decoder(item1, opts)
          let e1 = prepend_path(e1, "1")
          let #(v2, e2) = third.decoder(item2, opts)
          let e2 = prepend_path(e2, "2")
          let #(v3, e3) = fourth.decoder(item3, opts)
          let e3 = prepend_path(e3, "3")
          let #(v4, e4) = fifth.decoder(item4, opts)
          let e4 = prepend_path(e4, "4")
          let #(v5, e5) = sixth.decoder(item5, opts)
          let e5 = prepend_path(e5, "5")
          #(#(v0, v1, v2, v3, v4, v5), list.flatten([e0, e1, e2, e3, e4, e5]))
        }
        _ -> #(
          #(
            first.zero,
            second.zero,
            third.zero,
            fourth.zero,
            fifth.zero,
            sixth.zero,
          ),
          [
            TypeError(
              "Tuple[6]",
              "Array[" <> int.to_string(list.length(items)) <> "]",
              [],
            ),
          ],
        )
      }
    Error(_) -> #(
      #(
        first.zero,
        second.zero,
        third.zero,
        fourth.zero,
        fifth.zero,
        sixth.zero,
      ),
      [
        TypeError("Tuple[6]", dynamic.classify(data), []),
      ],
    )
  }
}

fn try_decoders(
  data: Dynamic,
  opts: Options,
  schemas: List(JsonSchema(a)),
  fallback: JsonSchema(a),
  type_name: String,
) -> #(a, List(ValidationError)) {
  case schemas {
    [] -> {
      let #(value, _) = fallback.decoder(data, opts)
      #(value, [TypeError(type_name, dynamic.classify(data), [])])
    }
    [sch, ..rest] -> {
      let #(value, errors) = sch.decoder(data, opts)
      case errors {
        [] -> #(value, [])
        _ -> try_decoders(data, opts, rest, fallback, type_name)
      }
    }
  }
}

fn prepend_path(
  errors: List(ValidationError),
  segment: String,
) -> List(ValidationError) {
  list.map(errors, fn(error) {
    case error {
      TypeError(expected, found, path) ->
        TypeError(expected, found, [segment, ..path])
      ConstraintError(violation, path) ->
        ConstraintError(violation, [segment, ..path])
      MissingField(fld, path) -> MissingField(fld, [segment, ..path])
      UnknownVariant(value, expected, path) ->
        UnknownVariant(value, expected, [segment, ..path])
      ConstMismatch(expected, actual, path) ->
        ConstMismatch(expected, actual, [segment, ..path])
    }
  })
}

fn build_object_schema(
  name: String,
  field_schema: JsonSchema(a),
  next_schema: JsonSchema(final),
) -> SchemaDefinition {
  case next_schema.schema {
    ObjectSchema(properties, required, additional, meta) -> {
      let new_properties = [Property(name, field_schema.schema), ..properties]
      let new_required = [name, ..required]
      ObjectSchema(new_properties, new_required, additional, meta)
    }
    _ -> next_schema.schema
  }
}

fn build_object_schema_optional(
  name: String,
  field_schema: JsonSchema(a),
  next_schema: JsonSchema(final),
) -> SchemaDefinition {
  case next_schema.schema {
    ObjectSchema(properties, required, additional, meta) -> {
      let new_properties = [Property(name, field_schema.schema), ..properties]
      ObjectSchema(new_properties, required, additional, meta)
    }
    _ -> next_schema.schema
  }
}

fn get_field(data: Dynamic, name: String) -> Result(Option(Dynamic), Nil) {
  case
    decode.run(data, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil)
  {
    Ok(d) -> Ok(dict.get(d, name) |> option.from_result)
    Error(_) -> Error(Nil)
  }
}

fn update_metadata(
  schema: JsonSchema(a),
  update: fn(Metadata) -> Metadata,
) -> JsonSchema(a) {
  let JsonSchema(def, decoder, zero) = schema
  let new_def = case def {
    StringSchema(constraints, meta) -> StringSchema(constraints, update(meta))
    IntegerSchema(constraints, meta) -> IntegerSchema(constraints, update(meta))
    NumberSchema(constraints, meta) -> NumberSchema(constraints, update(meta))
    BooleanSchema(meta) -> BooleanSchema(update(meta))
    NullSchema(meta) -> NullSchema(update(meta))
    ArraySchema(items, constraints, meta) ->
      ArraySchema(items, constraints, update(meta))
    ObjectSchema(properties, required, additional, meta) ->
      ObjectSchema(properties, required, additional, update(meta))
    DictSchema(value_schema, meta) -> DictSchema(value_schema, update(meta))
    NullableSchema(inner, meta) -> NullableSchema(inner, update(meta))
    OneOfSchema(variants, meta) -> OneOfSchema(variants, update(meta))
    AnyOfSchema(variants, meta) -> AnyOfSchema(variants, update(meta))
    EnumSchema(values, meta) -> EnumSchema(values, update(meta))
    ConstSchema(value, meta) -> ConstSchema(value, update(meta))
    TupleSchema(items, meta) -> TupleSchema(items, update(meta))
  }
  JsonSchema(schema: new_def, decoder:, zero:)
}

/// Validate IPv6 address format
/// Handles full, compressed (::), and mixed IPv4 formats
fn validate_ipv6(value: String) -> Bool {
  case value {
    "" -> False
    _ -> {
      // Check for IPv4-mapped addresses (::ffff:192.168.1.1)
      case string.contains(value, ".") {
        True -> validate_ipv6_mixed(value)
        False -> validate_ipv6_pure(value)
      }
    }
  }
}

fn validate_ipv6_pure(value: String) -> Bool {
  let parts = string.split(value, ":")
  let part_count = list.length(parts)
  let has_compression = string.contains(value, "::")

  case has_compression {
    True -> {
      // Can't have more than one ::
      case count_substring(value, "::") > 1 {
        True -> False
        False -> {
          let non_empty = list.filter(parts, fn(p) { p != "" })
          // Must have at most 7 non-empty parts with compression
          list.length(non_empty) <= 7
          && list.all(non_empty, is_valid_ipv6_segment)
        }
      }
    }
    False -> {
      // Without compression, must have exactly 8 parts
      part_count == 8 && list.all(parts, is_valid_ipv6_segment)
    }
  }
}

fn validate_ipv6_mixed(value: String) -> Bool {
  let parts = string.split(value, ":")
  let part_count = list.length(parts)
  case part_count >= 2 {
    False -> False
    True -> {
      let assert Ok(ipv4_part) = list.last(parts)
      let ipv6_parts = list.take(parts, part_count - 1)

      case validate_ipv4_format(ipv4_part) {
        False -> False
        True -> {
          let has_compression = string.contains(value, "::")
          let non_empty_ipv6 = list.filter(ipv6_parts, fn(p) { p != "" })

          case has_compression {
            True -> {
              case count_substring(value, "::") > 1 {
                True -> False
                False ->
                  list.length(non_empty_ipv6) <= 5
                  && list.all(non_empty_ipv6, is_valid_ipv6_segment)
              }
            }
            False ->
              list.length(ipv6_parts) == 6
              && list.all(ipv6_parts, is_valid_ipv6_segment)
          }
        }
      }
    }
  }
}

fn is_valid_ipv6_segment(segment: String) -> Bool {
  let len = string.length(segment)
  case len >= 1 && len <= 4 {
    False -> False
    True -> {
      segment
      |> string.lowercase
      |> string.to_graphemes
      |> list.all(fn(c) {
        case c {
          "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
          "a" | "b" | "c" | "d" | "e" | "f" -> True
          _ -> False
        }
      })
    }
  }
}

fn validate_ipv4_format(value: String) -> Bool {
  let parts = string.split(value, ".")
  case list.length(parts) == 4 {
    False -> False
    True ->
      list.all(parts, fn(p) {
        case int.parse(p) {
          Ok(n) -> n >= 0 && n <= 255
          Error(_) -> False
        }
      })
  }
}

fn count_substring(haystack: String, needle: String) -> Int {
  count_substring_loop(haystack, needle, 0)
}

fn count_substring_loop(haystack: String, needle: String, count: Int) -> Int {
  case string.split_once(haystack, needle) {
    Error(_) -> count
    Ok(#(_, rest)) -> count_substring_loop(rest, needle, count + 1)
  }
}

fn validate_format(value: String, fmt: StringFormat) -> Bool {
  case fmt {
    Email -> {
      let assert Ok(re) = regexp.from_string("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")
      regexp.check(re, value)
    }
    Uri -> validate_uri(value)
    DateTime -> {
      case timestamp.parse_rfc3339(value) {
        Ok(_) -> True
        Error(_) -> False
      }
    }
    Date -> validate_date_format(value)
    Time -> validate_time_format(value)
    Uuid -> {
      case uuid.from_string(value) {
        Ok(_) -> True
        Error(_) -> False
      }
    }
    Hostname -> {
      let assert Ok(re) =
        regexp.from_string(
          "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$",
        )
      regexp.check(re, value)
    }
    Ipv4 -> {
      let assert Ok(re) =
        regexp.from_string(
          "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$",
        )
      regexp.check(re, value)
    }
    Ipv6 -> validate_ipv6(value)
  }
}

/// Validate date format (YYYY-MM-DD) with actual date validation
fn validate_date_format(value: String) -> Bool {
  let assert Ok(re) = regexp.from_string("^(\\d{4})-(\\d{2})-(\\d{2})$")
  case regexp.scan(re, value) {
    [regexp.Match(_, [Some(year_str), Some(month_str), Some(day_str)])] -> {
      case int.parse(year_str), int.parse(month_str), int.parse(day_str) {
        Ok(year), Ok(month), Ok(day) -> is_valid_date(year, month, day)
        _, _, _ -> False
      }
    }
    _ -> False
  }
}

/// Check if a date is valid
fn is_valid_date(year: Int, month: Int, day: Int) -> Bool {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> day >= 1 && day <= 31
    4 | 6 | 9 | 11 -> day >= 1 && day <= 30
    2 -> {
      let is_leap = is_leap_year(year)
      let max_day = case is_leap {
        True -> 29
        False -> 28
      }
      day >= 1 && day <= max_day
    }
    _ -> False
  }
}

/// Check if a year is a leap year
fn is_leap_year(year: Int) -> Bool {
  { year % 4 == 0 && year % 100 != 0 } || year % 400 == 0
}

/// Validate time format (HH:MM:SS or HH:MM:SS.sss) with actual time validation
fn validate_time_format(value: String) -> Bool {
  let assert Ok(re) =
    regexp.from_string("^(\\d{2}):(\\d{2}):(\\d{2})(\\.\\d+)?$")
  case regexp.scan(re, value) {
    [regexp.Match(_, [Some(hour_str), Some(minute_str), Some(second_str), ..])] -> {
      case int.parse(hour_str), int.parse(minute_str), int.parse(second_str) {
        Ok(hour), Ok(minute), Ok(second) ->
          hour >= 0
          && hour <= 23
          && minute >= 0
          && minute <= 59
          && second >= 0
          && second <= 60
        // 60 for leap seconds
        _, _, _ -> False
      }
    }
    _ -> False
  }
}

fn float_modulo(a: Float, b: Float) -> Float {
  a -. { int.to_float(float.truncate(a /. b)) *. b }
}

/// Validate URI format - requires valid URI structure with a scheme.
/// Used by both uri() schema and format(Uri) validator for consistency.
fn validate_uri(value: String) -> Bool {
  case uri.parse(value) {
    Ok(parsed) ->
      // Must have a scheme to be a valid absolute URI per JSON Schema
      case parsed.scheme {
        Some(_) -> True
        None -> False
      }
    Error(_) -> False
  }
}

/// Check if dynamic data is null/nil/undefined
fn is_null(data: Dynamic) -> Bool {
  case decode.run(data, decode.optional(decode.dynamic)) {
    Ok(None) -> True
    _ -> False
  }
}

/// Convert StringFormat to JSON Schema format string
fn string_format_to_string(fmt: StringFormat) -> String {
  case fmt {
    Email -> "email"
    Uri -> "uri"
    DateTime -> "date-time"
    Date -> "date"
    Time -> "time"
    Uuid -> "uuid"
    Hostname -> "hostname"
    Ipv4 -> "ipv4"
    Ipv6 -> "ipv6"
  }
}
