import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleeunit
import sextant
import youid/uuid

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Primitive Schema Tests
// ---------------------------------------------------------------------------

pub fn string_schema_valid_test() {
  let schema = sextant.string()
  assert sextant.run(dynamic.string("hello"), schema) == Ok("hello")
}

pub fn string_schema_invalid_test() {
  let schema = sextant.string()
  assert sextant.run(dynamic.int(123), schema) |> result.is_error
}

pub fn integer_schema_valid_test() {
  let schema = sextant.integer()
  assert sextant.run(dynamic.int(42), schema) == Ok(42)
}

pub fn integer_schema_invalid_test() {
  let schema = sextant.integer()
  assert sextant.run(dynamic.string("not an int"), schema) |> result.is_error
}

pub fn number_schema_valid_test() {
  let schema = sextant.number()
  assert sextant.run(dynamic.float(3.14), schema) == Ok(3.14)
}

pub fn boolean_schema_valid_test() {
  let schema = sextant.boolean()
  assert sextant.run(dynamic.bool(True), schema) == Ok(True)
  assert sextant.run(dynamic.bool(False), schema) == Ok(False)
}

pub fn null_schema_valid_test() {
  let schema = sextant.null()
  assert sextant.run(dynamic.nil(), schema) == Ok(Nil)
}

// ---------------------------------------------------------------------------
// Typed Schema Tests (UUID, Timestamp, URI)
// ---------------------------------------------------------------------------

pub fn uuid_schema_valid_test() {
  let schema = sextant.uuid()
  let uuid_str = "550e8400-e29b-41d4-a716-446655440000"
  let assert Ok(id) = sextant.run(dynamic.string(uuid_str), schema)
  assert uuid.to_string(id) == uuid_str
}

pub fn uuid_schema_invalid_test() {
  let schema = sextant.uuid()
  assert sextant.run(dynamic.string("not-a-uuid"), schema) |> result.is_error
}

pub fn uuid_schema_wrong_type_test() {
  let schema = sextant.uuid()
  assert sextant.run(dynamic.int(123), schema) |> result.is_error
}

pub fn timestamp_schema_valid_test() {
  let schema = sextant.timestamp()
  let ts_str = "2024-12-25T12:30:00Z"
  let assert Ok(ts) = sextant.run(dynamic.string(ts_str), schema)
  let #(secs, _) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  assert secs == 1_735_129_800
}

pub fn timestamp_schema_invalid_test() {
  let schema = sextant.timestamp()
  assert sextant.run(dynamic.string("not-a-timestamp"), schema)
    |> result.is_error
}

pub fn timestamp_schema_wrong_type_test() {
  let schema = sextant.timestamp()
  assert sextant.run(dynamic.int(123), schema) |> result.is_error
}

pub fn uri_schema_valid_test() {
  let schema = sextant.uri()
  let uri_str = "https://example.com:8080/path?query=1#fragment"
  let assert Ok(u) = sextant.run(dynamic.string(uri_str), schema)
  assert u.scheme == Some("https")
  assert u.host == Some("example.com")
  assert u.port == Some(8080)
  assert u.path == "/path"
  assert u.query == Some("query=1")
  assert u.fragment == Some("fragment")
}

pub fn uri_schema_simple_test() {
  let schema = sextant.uri()
  let assert Ok(u) = sextant.run(dynamic.string("https://gleam.run"), schema)
  assert u.scheme == Some("https")
  assert u.host == Some("gleam.run")
}

pub fn uri_schema_wrong_type_test() {
  let schema = sextant.uri()
  assert sextant.run(dynamic.int(123), schema) |> result.is_error
}

pub fn uri_schema_requires_scheme_test() {
  // URIs without a scheme should be rejected
  let schema = sextant.uri()
  assert sextant.run(dynamic.string("/path/only"), schema) |> result.is_error
  assert sextant.run(dynamic.string("example.com"), schema) |> result.is_error
  assert sextant.run(dynamic.string("?query=1"), schema) |> result.is_error
  assert sextant.run(dynamic.string("#fragment"), schema) |> result.is_error
}

pub fn format_uri_requires_scheme_test() {
  // format(Uri) should also require a scheme
  let schema = sextant.string() |> sextant.format(sextant.Uri)
  let opts = sextant.Options(validate_formats: True)

  // Valid URIs with scheme
  assert sextant.run_with_options(
      dynamic.string("https://example.com"),
      schema,
      opts,
    )
    == Ok("https://example.com")
  assert sextant.run_with_options(dynamic.string("file:///path"), schema, opts)
    == Ok("file:///path")

  // Invalid: no scheme
  assert sextant.run_with_options(dynamic.string("/path/only"), schema, opts)
    |> result.is_error
  assert sextant.run_with_options(dynamic.string("example.com"), schema, opts)
    |> result.is_error
}

// ---------------------------------------------------------------------------
// Object Schema Tests
// ---------------------------------------------------------------------------

pub type User {
  User(name: String, age: Int)
}

fn user_schema() -> sextant.JsonSchema(User) {
  use name <- sextant.field("name", sextant.string())
  use age <- sextant.field("age", sextant.integer())
  sextant.success(User(name:, age:))
}

pub fn object_schema_valid_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("age"), dynamic.int(30)),
    ])
  assert sextant.run(data, user_schema()) == Ok(User("Alice", 30))
}

pub fn object_schema_missing_field_test() {
  let data =
    dynamic.properties([#(dynamic.string("name"), dynamic.string("Alice"))])
  assert sextant.run(data, user_schema())
    == Error([sextant.MissingField("age", [])])
}

pub fn object_schema_wrong_type_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("age"), dynamic.string("not an int")),
    ])
  assert sextant.run(data, user_schema()) |> result.is_error
}

// ---------------------------------------------------------------------------
// Optional Field Tests
// ---------------------------------------------------------------------------

pub type UserWithEmail {
  UserWithEmail(name: String, email: option.Option(String))
}

fn user_with_email_schema() -> sextant.JsonSchema(UserWithEmail) {
  use name <- sextant.field("name", sextant.string())
  use email <- sextant.optional_field("email", sextant.string())
  sextant.success(UserWithEmail(name:, email:))
}

pub fn optional_field_present_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("email"), dynamic.string("alice@example.com")),
    ])
  assert sextant.run(data, user_with_email_schema())
    == Ok(UserWithEmail("Alice", Some("alice@example.com")))
}

pub fn optional_field_missing_test() {
  let data =
    dynamic.properties([#(dynamic.string("name"), dynamic.string("Alice"))])
  assert sextant.run(data, user_with_email_schema())
    == Ok(UserWithEmail("Alice", None))
}

pub fn optional_field_null_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("email"), dynamic.nil()),
    ])
  assert sextant.run(data, user_with_email_schema())
    == Ok(UserWithEmail("Alice", None))
}

// ---------------------------------------------------------------------------
// Tuple Schema Tests
// ---------------------------------------------------------------------------

pub fn tuple2_schema_valid_test() {
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  let data = dynamic.list([dynamic.string("hello"), dynamic.int(42)])
  assert sextant.run(data, schema) == Ok(#("hello", 42))
}

pub fn tuple2_schema_wrong_length_test() {
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  // Too few elements
  let data = dynamic.list([dynamic.string("hello")])
  assert sextant.run(data, schema) |> result.is_error
  // Too many elements
  let data2 =
    dynamic.list([dynamic.string("a"), dynamic.int(1), dynamic.int(2)])
  assert sextant.run(data2, schema) |> result.is_error
}

pub fn tuple2_schema_wrong_type_test() {
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  // Wrong element type
  let data = dynamic.list([dynamic.string("hello"), dynamic.string("world")])
  assert sextant.run(data, schema) |> result.is_error
}

pub fn tuple2_schema_not_array_test() {
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  assert sextant.run(dynamic.string("not an array"), schema) |> result.is_error
}

pub fn tuple3_schema_valid_test() {
  let schema =
    sextant.tuple3(sextant.string(), sextant.integer(), sextant.boolean())
  let data =
    dynamic.list([dynamic.string("a"), dynamic.int(1), dynamic.bool(True)])
  assert sextant.run(data, schema) == Ok(#("a", 1, True))
}

pub fn tuple4_schema_valid_test() {
  let schema =
    sextant.tuple4(
      sextant.string(),
      sextant.integer(),
      sextant.boolean(),
      sextant.number(),
    )
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.int(1),
      dynamic.bool(True),
      dynamic.float(3.14),
    ])
  assert sextant.run(data, schema) == Ok(#("a", 1, True, 3.14))
}

pub fn tuple_schema_accumulates_errors_test() {
  // Both elements have wrong types - should report both errors
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  let data = dynamic.list([dynamic.int(123), dynamic.string("wrong")])
  let assert Error(errors) = sextant.run(data, schema)
  assert list.length(errors) == 2
}

pub fn tuple_schema_with_constraints_test() {
  // Tuple with constrained elements
  let schema =
    sextant.tuple2(
      sextant.string() |> sextant.min_length(3),
      sextant.integer() |> sextant.int_min(0),
    )
  // Valid
  assert sextant.run(
      dynamic.list([dynamic.string("hello"), dynamic.int(5)]),
      schema,
    )
    == Ok(#("hello", 5))
  // First element too short
  let assert Error(_) =
    sextant.run(dynamic.list([dynamic.string("ab"), dynamic.int(5)]), schema)
  // Second element too small
  let assert Error(_) =
    sextant.run(
      dynamic.list([dynamic.string("hello"), dynamic.int(-1)]),
      schema,
    )
}

pub fn tuple2_schema_json_test() {
  let schema = sextant.tuple2(sextant.string(), sextant.integer())
  assert sextant.to_json(schema)
    == json.object([
      #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
      #("type", json.string("array")),
      #(
        "prefixItems",
        json.array(
          [
            json.object([#("type", json.string("string"))]),
            json.object([#("type", json.string("integer"))]),
          ],
          fn(x) { x },
        ),
      ),
      #("items", json.bool(False)),
      #("minItems", json.int(2)),
      #("maxItems", json.int(2)),
    ])
}

pub fn tuple3_schema_json_test() {
  let schema =
    sextant.tuple3(sextant.string(), sextant.integer(), sextant.boolean())
  let schema_json = sextant.to_json(schema) |> json.to_string
  assert string.contains(schema_json, "prefixItems")
  assert string.contains(schema_json, "\"minItems\":3")
  assert string.contains(schema_json, "\"maxItems\":3")
}

// ---------------------------------------------------------------------------
// Array Schema Tests
// ---------------------------------------------------------------------------

pub fn array_schema_valid_test() {
  let schema = sextant.array(of: sextant.string())
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.string("b"),
      dynamic.string("c"),
    ])
  assert sextant.run(data, schema) == Ok(["a", "b", "c"])
}

pub fn array_schema_empty_test() {
  let schema = sextant.array(of: sextant.integer())
  let data = dynamic.list([])
  assert sextant.run(data, schema) == Ok([])
}

pub fn array_schema_wrong_item_type_test() {
  let schema = sextant.array(of: sextant.integer())
  let data = dynamic.list([dynamic.string("not"), dynamic.string("integers")])
  assert sextant.run(data, schema) |> result.is_error
}

// ---------------------------------------------------------------------------
// Dict Schema Tests
// ---------------------------------------------------------------------------

pub fn dict_schema_valid_test() {
  let schema = sextant.dict(sextant.integer())
  let data =
    dynamic.properties([
      #(dynamic.string("alice"), dynamic.int(100)),
      #(dynamic.string("bob"), dynamic.int(85)),
    ])
  let assert Ok(result) = sextant.run(data, schema)
  assert dict.get(result, "alice") == Ok(100)
  assert dict.get(result, "bob") == Ok(85)
}

pub fn dict_schema_with_nested_errors_test() {
  // Dict with constrained values - each invalid value should report an error with path
  let schema = sextant.dict(sextant.integer() |> sextant.int_min(0))
  let data =
    dynamic.properties([
      #(dynamic.string("alice"), dynamic.int(-1)),
      #(dynamic.string("bob"), dynamic.int(-2)),
      #(dynamic.string("carol"), dynamic.int(10)),
    ])
  let assert Error(errors) = sextant.run(data, schema)
  // Should have 2 errors (alice and bob), each with path
  assert list.length(errors) == 2
  // All errors should have paths
  assert list.all(errors, fn(e) {
    case e {
      sextant.ConstraintError(_, path) -> path != []
      _ -> False
    }
  })
}

pub fn dict_schema_with_type_errors_test() {
  // Dict where values have wrong types
  let schema = sextant.dict(sextant.string())
  let data =
    dynamic.properties([
      #(dynamic.string("a"), dynamic.int(1)),
      #(dynamic.string("b"), dynamic.string("valid")),
      #(dynamic.string("c"), dynamic.int(2)),
    ])
  let assert Error(errors) = sextant.run(data, schema)
  // Should have 2 errors (a and c)
  assert list.length(errors) == 2
}

// ---------------------------------------------------------------------------
// Nullable Schema Tests
// ---------------------------------------------------------------------------

pub fn optional_schema_value_test() {
  let schema = sextant.optional(sextant.string())
  assert sextant.run(dynamic.string("hello"), schema) == Ok(Some("hello"))
}

pub fn optional_schema_null_test() {
  let schema = sextant.optional(sextant.string())
  assert sextant.run(dynamic.nil(), schema) == Ok(None)
}

// ---------------------------------------------------------------------------
// Literal (Enum) Schema Tests
// ---------------------------------------------------------------------------

pub type Role {
  Admin
  Member
  Guest
}

fn role_schema() -> sextant.JsonSchema(Role) {
  sextant.enum(#("admin", Admin), [#("member", Member), #("guest", Guest)])
}

pub fn enum_schema_valid_test() {
  assert sextant.run(dynamic.string("admin"), role_schema()) == Ok(Admin)
  assert sextant.run(dynamic.string("member"), role_schema()) == Ok(Member)
  assert sextant.run(dynamic.string("guest"), role_schema()) == Ok(Guest)
}

pub fn enum_schema_unknown_variant_test() {
  assert sextant.run(dynamic.string("superuser"), role_schema())
    == Error([
      sextant.UnknownVariant("superuser", ["admin", "member", "guest"], []),
    ])
}

// ---------------------------------------------------------------------------
// String Constraint Tests
// ---------------------------------------------------------------------------

pub fn min_length_valid_test() {
  let schema = sextant.string() |> sextant.min_length(3)
  assert sextant.run(dynamic.string("hello"), schema) == Ok("hello")
}

pub fn min_length_invalid_test() {
  let schema = sextant.string() |> sextant.min_length(5)
  assert sextant.run(dynamic.string("hi"), schema)
    == Error([
      sextant.ConstraintError(
        sextant.StringViolation(sextant.StringTooShort(5, 2)),
        [],
      ),
    ])
}

pub fn max_length_valid_test() {
  let schema = sextant.string() |> sextant.max_length(10)
  assert sextant.run(dynamic.string("hello"), schema) == Ok("hello")
}

pub fn max_length_invalid_test() {
  let schema = sextant.string() |> sextant.max_length(3)
  assert sextant.run(dynamic.string("hello"), schema) |> result.is_error
}

pub fn error_accumulation_string_constraints_test() {
  // A string that violates both min_length and pattern should report both errors
  let schema =
    sextant.string()
    |> sextant.min_length(10)
    |> sextant.pattern("^[a-z]+$")

  let result = sextant.run(dynamic.string("AB"), schema)
  let assert Error(errors) = result

  // Should have 2 errors: too short AND pattern mismatch
  assert list.length(errors) == 2
}

pub fn error_accumulation_int_constraints_test() {
  // An integer that violates both min and multiple_of should report both errors
  let schema =
    sextant.integer()
    |> sextant.int_min(10)
    |> sextant.int_multiple_of(5)

  let result = sextant.run(dynamic.int(3), schema)
  let assert Error(errors) = result

  // Should have 2 errors: too small AND not multiple of 5
  assert list.length(errors) == 2
}

pub fn error_accumulation_stops_on_type_error_test() {
  // Type errors should stop constraint checking (can't check length of non-string)
  let schema =
    sextant.string()
    |> sextant.min_length(5)
    |> sextant.max_length(10)

  let result = sextant.run(dynamic.int(42), schema)
  let assert Error(errors) = result

  // Should only have 1 error: type error (constraints not checked)
  assert list.length(errors) == 1
  let assert [sextant.TypeError(_, _, _)] = errors
}

pub fn pattern_valid_test() {
  let schema = sextant.string() |> sextant.pattern("^[a-z]+$")
  assert sextant.run(dynamic.string("hello"), schema) == Ok("hello")
}

pub fn pattern_invalid_test() {
  let schema = sextant.string() |> sextant.pattern("^[a-z]+$")
  assert sextant.run(dynamic.string("Hello123"), schema) |> result.is_error
}

pub fn pattern_invalid_regex_test() {
  // Invalid regex should return InvalidPattern error
  let schema = sextant.string() |> sextant.pattern("[invalid(regex")
  let result = sextant.run(dynamic.string("test"), schema)
  let assert Error([
    sextant.ConstraintError(
      sextant.StringViolation(sextant.InvalidPattern(_, _)),
      _,
    ),
  ]) = result
}

// ---------------------------------------------------------------------------
// Integer Constraint Tests
// ---------------------------------------------------------------------------

pub fn int_min_valid_test() {
  let schema = sextant.integer() |> sextant.int_min(0)
  assert sextant.run(dynamic.int(5), schema) == Ok(5)
}

pub fn int_min_invalid_test() {
  let schema = sextant.integer() |> sextant.int_min(10)
  assert sextant.run(dynamic.int(5), schema) |> result.is_error
}

pub fn int_max_valid_test() {
  let schema = sextant.integer() |> sextant.int_max(100)
  assert sextant.run(dynamic.int(50), schema) == Ok(50)
}

pub fn int_max_invalid_test() {
  let schema = sextant.integer() |> sextant.int_max(10)
  assert sextant.run(dynamic.int(50), schema) |> result.is_error
}

pub fn int_multiple_of_valid_test() {
  let schema = sextant.integer() |> sextant.int_multiple_of(5)
  assert sextant.run(dynamic.int(15), schema) == Ok(15)
}

pub fn int_multiple_of_invalid_test() {
  let schema = sextant.integer() |> sextant.int_multiple_of(5)
  assert sextant.run(dynamic.int(7), schema) |> result.is_error
}

pub fn int_exclusive_min_valid_test() {
  let schema = sextant.integer() |> sextant.int_exclusive_min(0)
  assert sextant.run(dynamic.int(1), schema) == Ok(1)
}

pub fn int_exclusive_min_boundary_test() {
  // Boundary value should fail (exclusive)
  let schema = sextant.integer() |> sextant.int_exclusive_min(0)
  assert sextant.run(dynamic.int(0), schema) |> result.is_error
}

pub fn int_exclusive_min_invalid_test() {
  let schema = sextant.integer() |> sextant.int_exclusive_min(0)
  assert sextant.run(dynamic.int(-1), schema) |> result.is_error
}

pub fn int_exclusive_max_valid_test() {
  let schema = sextant.integer() |> sextant.int_exclusive_max(100)
  assert sextant.run(dynamic.int(99), schema) == Ok(99)
}

pub fn int_exclusive_max_boundary_test() {
  // Boundary value should fail (exclusive)
  let schema = sextant.integer() |> sextant.int_exclusive_max(100)
  assert sextant.run(dynamic.int(100), schema) |> result.is_error
}

pub fn int_exclusive_max_invalid_test() {
  let schema = sextant.integer() |> sextant.int_exclusive_max(100)
  assert sextant.run(dynamic.int(101), schema) |> result.is_error
}

// ---------------------------------------------------------------------------
// Float Constraint Tests
// ---------------------------------------------------------------------------

pub fn float_min_valid_test() {
  let schema = sextant.number() |> sextant.float_min(0.0)
  assert sextant.run(dynamic.float(5.5), schema) == Ok(5.5)
}

pub fn float_min_boundary_test() {
  let schema = sextant.number() |> sextant.float_min(0.0)
  assert sextant.run(dynamic.float(0.0), schema) == Ok(0.0)
}

pub fn float_min_invalid_test() {
  let schema = sextant.number() |> sextant.float_min(10.0)
  assert sextant.run(dynamic.float(5.5), schema) |> result.is_error
}

pub fn float_max_valid_test() {
  let schema = sextant.number() |> sextant.float_max(100.0)
  assert sextant.run(dynamic.float(50.5), schema) == Ok(50.5)
}

pub fn float_max_boundary_test() {
  let schema = sextant.number() |> sextant.float_max(100.0)
  assert sextant.run(dynamic.float(100.0), schema) == Ok(100.0)
}

pub fn float_max_invalid_test() {
  let schema = sextant.number() |> sextant.float_max(10.0)
  assert sextant.run(dynamic.float(50.5), schema) |> result.is_error
}

pub fn float_exclusive_min_valid_test() {
  let schema = sextant.number() |> sextant.float_exclusive_min(0.0)
  assert sextant.run(dynamic.float(0.1), schema) == Ok(0.1)
}

pub fn float_exclusive_min_boundary_test() {
  // Boundary value should fail (exclusive)
  let schema = sextant.number() |> sextant.float_exclusive_min(0.0)
  assert sextant.run(dynamic.float(0.0), schema) |> result.is_error
}

pub fn float_exclusive_min_invalid_test() {
  let schema = sextant.number() |> sextant.float_exclusive_min(0.0)
  assert sextant.run(dynamic.float(-0.1), schema) |> result.is_error
}

pub fn float_exclusive_max_valid_test() {
  let schema = sextant.number() |> sextant.float_exclusive_max(100.0)
  assert sextant.run(dynamic.float(99.9), schema) == Ok(99.9)
}

pub fn float_exclusive_max_boundary_test() {
  // Boundary value should fail (exclusive)
  let schema = sextant.number() |> sextant.float_exclusive_max(100.0)
  assert sextant.run(dynamic.float(100.0), schema) |> result.is_error
}

pub fn float_exclusive_max_invalid_test() {
  let schema = sextant.number() |> sextant.float_exclusive_max(100.0)
  assert sextant.run(dynamic.float(100.1), schema) |> result.is_error
}

pub fn float_multiple_of_valid_test() {
  let schema = sextant.number() |> sextant.float_multiple_of(0.25)
  assert sextant.run(dynamic.float(1.5), schema) == Ok(1.5)
}

pub fn float_multiple_of_invalid_test() {
  let schema = sextant.number() |> sextant.float_multiple_of(0.25)
  assert sextant.run(dynamic.float(1.3), schema) |> result.is_error
}

// ---------------------------------------------------------------------------
// Array Constraint Tests
// ---------------------------------------------------------------------------

pub fn min_items_valid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.min_items(2)
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.string("b"),
      dynamic.string("c"),
    ])
  assert sextant.run(data, schema) == Ok(["a", "b", "c"])
}

pub fn min_items_invalid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.min_items(3)
  assert sextant.run(dynamic.list([dynamic.string("a")]), schema)
    |> result.is_error
}

pub fn max_items_valid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.max_items(5)
  let data = dynamic.list([dynamic.string("a"), dynamic.string("b")])
  assert sextant.run(data, schema) == Ok(["a", "b"])
}

pub fn max_items_invalid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.max_items(2)
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.string("b"),
      dynamic.string("c"),
      dynamic.string("d"),
    ])
  assert sextant.run(data, schema) |> result.is_error
}

pub fn unique_items_valid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.unique_items()
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.string("b"),
      dynamic.string("c"),
    ])
  assert sextant.run(data, schema) == Ok(["a", "b", "c"])
}

pub fn unique_items_invalid_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.unique_items()
  let data =
    dynamic.list([
      dynamic.string("a"),
      dynamic.string("b"),
      dynamic.string("a"),
    ])
  assert sextant.run(data, schema) |> result.is_error
}

// ---------------------------------------------------------------------------
// Format Validation Tests
// ---------------------------------------------------------------------------

pub fn format_email_not_validated_by_default_test() {
  let schema = sextant.string() |> sextant.format(sextant.Email)
  assert sextant.run(dynamic.string("not-an-email"), schema)
    == Ok("not-an-email")
}

pub fn format_email_validated_when_enabled_test() {
  let schema = sextant.string() |> sextant.format(sextant.Email)
  let opts = sextant.Options(validate_formats: True)

  assert sextant.run_with_options(
      dynamic.string("test@example.com"),
      schema,
      opts,
    )
    == Ok("test@example.com")

  assert sextant.run_with_options(dynamic.string("not-an-email"), schema, opts)
    |> result.is_error
}

pub fn format_ipv6_valid_full_test() {
  let schema = sextant.string() |> sextant.format(sextant.Ipv6)
  let opts = sextant.Options(validate_formats: True)

  // Full format
  assert sextant.run_with_options(
      dynamic.string("2001:0db8:85a3:0000:0000:8a2e:0370:7334"),
      schema,
      opts,
    )
    == Ok("2001:0db8:85a3:0000:0000:8a2e:0370:7334")
}

pub fn format_ipv6_valid_compressed_test() {
  let schema = sextant.string() |> sextant.format(sextant.Ipv6)
  let opts = sextant.Options(validate_formats: True)

  // Loopback compressed
  assert sextant.run_with_options(dynamic.string("::1"), schema, opts)
    == Ok("::1")

  // Leading compression
  assert sextant.run_with_options(
      dynamic.string("::ffff:192.0.2.1"),
      schema,
      opts,
    )
    == Ok("::ffff:192.0.2.1")

  // Trailing compression
  assert sextant.run_with_options(dynamic.string("fe80::"), schema, opts)
    == Ok("fe80::")

  // Middle compression
  assert sextant.run_with_options(dynamic.string("2001:db8::1"), schema, opts)
    == Ok("2001:db8::1")
}

pub fn format_ipv6_valid_mixed_test() {
  let schema = sextant.string() |> sextant.format(sextant.Ipv6)
  let opts = sextant.Options(validate_formats: True)

  // IPv4-mapped IPv6
  assert sextant.run_with_options(
      dynamic.string("::ffff:192.168.1.1"),
      schema,
      opts,
    )
    == Ok("::ffff:192.168.1.1")

  // Full IPv6 with IPv4 suffix
  assert sextant.run_with_options(
      dynamic.string("2001:db8:85a3::8a2e:192.168.1.1"),
      schema,
      opts,
    )
    == Ok("2001:db8:85a3::8a2e:192.168.1.1")
}

pub fn format_ipv6_invalid_test() {
  let schema = sextant.string() |> sextant.format(sextant.Ipv6)
  let opts = sextant.Options(validate_formats: True)

  // Invalid: too many groups
  assert sextant.run_with_options(
      dynamic.string("2001:0db8:85a3:0000:0000:8a2e:0370:7334:extra"),
      schema,
      opts,
    )
    |> result.is_error

  // Invalid: non-hex characters
  assert sextant.run_with_options(
      dynamic.string("2001:0db8:85a3:ghij::1"),
      schema,
      opts,
    )
    |> result.is_error

  // Invalid: segment too long
  assert sextant.run_with_options(
      dynamic.string("2001:0db8:85a3:00000::1"),
      schema,
      opts,
    )
    |> result.is_error

  // Invalid: multiple ::
  assert sextant.run_with_options(dynamic.string("2001::85a3::1"), schema, opts)
    |> result.is_error

  // Invalid: plain string
  assert sextant.run_with_options(dynamic.string("not-an-ipv6"), schema, opts)
    |> result.is_error
}

pub fn format_date_valid_test() {
  let schema = sextant.string() |> sextant.format(sextant.Date)
  let opts = sextant.Options(validate_formats: True)

  assert sextant.run_with_options(dynamic.string("2024-01-15"), schema, opts)
    == Ok("2024-01-15")
  assert sextant.run_with_options(dynamic.string("2024-02-29"), schema, opts)
    == Ok("2024-02-29")
  // Leap year
}

pub fn format_date_invalid_test() {
  let schema = sextant.string() |> sextant.format(sextant.Date)
  let opts = sextant.Options(validate_formats: True)

  // Invalid month
  assert sextant.run_with_options(dynamic.string("2024-13-01"), schema, opts)
    |> result.is_error

  // Invalid day for month
  assert sextant.run_with_options(dynamic.string("2024-04-31"), schema, opts)
    |> result.is_error

  // Feb 29 on non-leap year
  assert sextant.run_with_options(dynamic.string("2023-02-29"), schema, opts)
    |> result.is_error

  // Invalid format
  assert sextant.run_with_options(dynamic.string("01-15-2024"), schema, opts)
    |> result.is_error
}

pub fn format_time_valid_test() {
  let schema = sextant.string() |> sextant.format(sextant.Time)
  let opts = sextant.Options(validate_formats: True)

  assert sextant.run_with_options(dynamic.string("14:30:00"), schema, opts)
    == Ok("14:30:00")
  assert sextant.run_with_options(dynamic.string("23:59:59"), schema, opts)
    == Ok("23:59:59")
  assert sextant.run_with_options(dynamic.string("00:00:00"), schema, opts)
    == Ok("00:00:00")
  // With fractional seconds
  assert sextant.run_with_options(dynamic.string("14:30:00.123"), schema, opts)
    == Ok("14:30:00.123")
}

pub fn format_time_invalid_test() {
  let schema = sextant.string() |> sextant.format(sextant.Time)
  let opts = sextant.Options(validate_formats: True)

  // Invalid hour
  assert sextant.run_with_options(dynamic.string("24:00:00"), schema, opts)
    |> result.is_error

  // Invalid minute
  assert sextant.run_with_options(dynamic.string("12:60:00"), schema, opts)
    |> result.is_error

  // Invalid second (61 is not valid, 60 is for leap seconds)
  assert sextant.run_with_options(dynamic.string("12:00:61"), schema, opts)
    |> result.is_error

  // Invalid format
  assert sextant.run_with_options(dynamic.string("2:30:00 PM"), schema, opts)
    |> result.is_error
}

// ---------------------------------------------------------------------------
// Map Transform Tests
// ---------------------------------------------------------------------------

pub fn map_transform_test() {
  let schema = sextant.string() |> sextant.map(string.uppercase)
  assert sextant.run(dynamic.string("hello"), schema) == Ok("HELLO")
}

type Slug {
  Slug(String)
}

fn parse_slug(s: String) -> Result(Slug, String) {
  let is_valid =
    string.length(s) > 0 && string.lowercase(s) == s && !string.contains(s, " ")
  case is_valid {
    True -> Ok(Slug(s))
    False -> Error("must be lowercase with no spaces")
  }
}

pub fn try_map_success_test() {
  let schema =
    sextant.string() |> sextant.try_map(parse_slug, default: Slug(""))

  assert sextant.run(dynamic.string("hello-world"), schema)
    == Ok(Slug("hello-world"))
}

pub fn try_map_failure_test() {
  let schema =
    sextant.string() |> sextant.try_map(parse_slug, default: Slug(""))

  // "Hello World" has uppercase and spaces
  assert sextant.run(dynamic.string("Hello World"), schema) |> result.is_error
}

pub fn try_map_accumulates_errors_test() {
  // try_map should accumulate errors with previous constraints
  let schema =
    sextant.string()
    |> sextant.min_length(5)
    |> sextant.try_map(parse_slug, default: Slug(""))

  // "AB" is both too short AND not a valid slug (uppercase)
  let result = sextant.run(dynamic.string("AB"), schema)
  let assert Error(errors) = result
  assert list.length(errors) == 2
}

// ---------------------------------------------------------------------------
// One Of Tests
// ---------------------------------------------------------------------------

pub type StringOrInt {
  StringValue(String)
  IntValue(Int)
}

pub fn one_of_first_matches_test() {
  let schema =
    sextant.one_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.run(dynamic.string("hello"), schema)
    == Ok(StringValue("hello"))
}

pub fn one_of_second_matches_test() {
  let schema =
    sextant.one_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.run(dynamic.int(42), schema) == Ok(IntValue(42))
}

pub fn one_of_none_matches_test() {
  let schema =
    sextant.one_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.run(dynamic.bool(True), schema) |> result.is_error
}

pub fn any_of_first_matches_test() {
  let schema =
    sextant.any_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.run(dynamic.string("hello"), schema)
    == Ok(StringValue("hello"))
}

pub fn any_of_second_matches_test() {
  let schema =
    sextant.any_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.run(dynamic.int(42), schema) == Ok(IntValue(42))
}

pub fn any_of_none_matches_test() {
  let schema =
    sextant.any_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  let result = sextant.run(dynamic.bool(True), schema)
  // Should have AnyOf in error, not OneOf
  let assert Error([sextant.TypeError("AnyOf", _, _)]) = result
}

// ---------------------------------------------------------------------------
// Nested Object Tests
// ---------------------------------------------------------------------------

pub type Address {
  Address(city: String, zip: String)
}

pub type Person {
  Person(name: String, address: Address)
}

fn address_schema() -> sextant.JsonSchema(Address) {
  use city <- sextant.field("city", sextant.string())
  use zip <- sextant.field("zip", sextant.string())
  sextant.success(Address(city:, zip:))
}

fn person_schema() -> sextant.JsonSchema(Person) {
  use name <- sextant.field("name", sextant.string())
  use address <- sextant.field("address", address_schema())
  sextant.success(Person(name:, address:))
}

pub fn nested_object_valid_test() {
  let address_data =
    dynamic.properties([
      #(dynamic.string("city"), dynamic.string("NYC")),
      #(dynamic.string("zip"), dynamic.string("10001")),
    ])
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("address"), address_data),
    ])
  assert sextant.run(data, person_schema())
    == Ok(Person("Alice", Address("NYC", "10001")))
}

pub fn nested_object_error_path_test() {
  let address_data =
    dynamic.properties([
      #(dynamic.string("city"), dynamic.string("NYC")),
      #(dynamic.string("zip"), dynamic.int(12_345)),
    ])
  let data =
    dynamic.properties([
      #(dynamic.string("name"), dynamic.string("Alice")),
      #(dynamic.string("address"), address_data),
    ])
  let assert Error([sextant.TypeError("String", _, ["address", "zip"])]) =
    sextant.run(data, person_schema())
}

// ---------------------------------------------------------------------------
// Deeply Nested Path Tests
// ---------------------------------------------------------------------------

pub type Level3 {
  Level3(value: String)
}

pub type Level2 {
  Level2(level3: Level3)
}

pub type Level1 {
  Level1(level2: Level2)
}

pub type Root {
  Root(level1: Level1)
}

fn level3_schema() -> sextant.JsonSchema(Level3) {
  use value <- sextant.field("value", sextant.string() |> sextant.min_length(5))
  sextant.success(Level3(value:))
}

fn level2_schema() -> sextant.JsonSchema(Level2) {
  use level3 <- sextant.field("level3", level3_schema())
  sextant.success(Level2(level3:))
}

fn level1_schema() -> sextant.JsonSchema(Level1) {
  use level2 <- sextant.field("level2", level2_schema())
  sextant.success(Level1(level2:))
}

fn root_schema() -> sextant.JsonSchema(Root) {
  use level1 <- sextant.field("level1", level1_schema())
  sextant.success(Root(level1:))
}

pub fn deeply_nested_path_4_levels_test() {
  // 4 levels deep: root.level1.level2.level3.value
  let level3_data =
    dynamic.properties([#(dynamic.string("value"), dynamic.string("ab"))])
  // "ab" is too short
  let level2_data =
    dynamic.properties([#(dynamic.string("level3"), level3_data)])
  let level1_data =
    dynamic.properties([#(dynamic.string("level2"), level2_data)])
  let root_data = dynamic.properties([#(dynamic.string("level1"), level1_data)])

  let assert Error([
    sextant.ConstraintError(_, ["level1", "level2", "level3", "value"]),
  ]) = sextant.run(root_data, root_schema())
}

pub fn deeply_nested_array_path_test() {
  // Array inside object: items.0.name
  let item_schema = {
    use name <- sextant.field("name", sextant.string())
    sextant.success(name)
  }
  let items_schema = sextant.array(of: item_schema)
  let container_schema = {
    use items <- sextant.field("items", items_schema)
    sextant.success(items)
  }

  let data =
    dynamic.properties([
      #(
        dynamic.string("items"),
        dynamic.list([
          dynamic.properties([#(dynamic.string("name"), dynamic.int(123))]),
        ]),
      ),
    ])

  let assert Error([sextant.TypeError("String", _, ["items", "0", "name"])]) =
    sextant.run(data, container_schema)
}

// ---------------------------------------------------------------------------
// Boundary Condition Tests
// ---------------------------------------------------------------------------

pub fn min_length_zero_accepts_empty_test() {
  let schema = sextant.string() |> sextant.min_length(0)
  assert sextant.run(dynamic.string(""), schema) == Ok("")
}

pub fn max_items_zero_accepts_empty_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.max_items(0)
  assert sextant.run(dynamic.list([]), schema) == Ok([])
}

pub fn max_items_zero_rejects_nonempty_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.max_items(0)
  assert sextant.run(dynamic.list([dynamic.string("a")]), schema)
    |> result.is_error
}

pub fn min_items_zero_accepts_empty_test() {
  let schema = sextant.array(of: sextant.string()) |> sextant.min_items(0)
  assert sextant.run(dynamic.list([]), schema) == Ok([])
}

pub fn int_min_boundary_test() {
  let schema = sextant.integer() |> sextant.int_min(5)
  // Exactly at boundary should pass
  assert sextant.run(dynamic.int(5), schema) == Ok(5)
  // Below boundary should fail
  assert sextant.run(dynamic.int(4), schema) |> result.is_error
}

pub fn int_max_boundary_test() {
  let schema = sextant.integer() |> sextant.int_max(10)
  // Exactly at boundary should pass
  assert sextant.run(dynamic.int(10), schema) == Ok(10)
  // Above boundary should fail
  assert sextant.run(dynamic.int(11), schema) |> result.is_error
}

pub fn string_exact_length_test() {
  let schema =
    sextant.string()
    |> sextant.min_length(5)
    |> sextant.max_length(5)
  assert sextant.run(dynamic.string("hello"), schema) == Ok("hello")
  assert sextant.run(dynamic.string("hi"), schema) |> result.is_error
  assert sextant.run(dynamic.string("hello!"), schema) |> result.is_error
}

// ---------------------------------------------------------------------------
// JSON Schema Generation Tests
// ---------------------------------------------------------------------------

fn schema_version() -> #(String, json.Json) {
  #("$schema", json.string("https://json-schema.org/draft/2020-12/schema"))
}

pub fn string_schema_json_test() {
  assert sextant.to_json(sextant.string())
    == json.object([schema_version(), #("type", json.string("string"))])
}

pub fn integer_schema_json_test() {
  assert sextant.to_json(sextant.integer())
    == json.object([schema_version(), #("type", json.string("integer"))])
}

pub fn number_schema_json_test() {
  assert sextant.to_json(sextant.number())
    == json.object([schema_version(), #("type", json.string("number"))])
}

pub fn boolean_schema_json_test() {
  assert sextant.to_json(sextant.boolean())
    == json.object([schema_version(), #("type", json.string("boolean"))])
}

pub fn null_schema_json_test() {
  assert sextant.to_json(sextant.null())
    == json.object([schema_version(), #("type", json.string("null"))])
}

pub fn array_schema_json_test() {
  assert sextant.to_json(sextant.array(of: sextant.string()))
    == json.object([
      schema_version(),
      #("type", json.string("array")),
      #("items", json.object([#("type", json.string("string"))])),
    ])
}

pub fn array_with_constraints_json_test() {
  let schema =
    sextant.array(of: sextant.integer())
    |> sextant.min_items(1)
    |> sextant.max_items(10)
    |> sextant.unique_items()
  assert sextant.to_json(schema)
    == json.object([
      schema_version(),
      #("uniqueItems", json.bool(True)),
      #("maxItems", json.int(10)),
      #("minItems", json.int(1)),
      #("type", json.string("array")),
      #("items", json.object([#("type", json.string("integer"))])),
    ])
}

pub fn object_schema_json_test() {
  assert sextant.to_json(user_schema())
    == json.object([
      schema_version(),
      #("required", json.array(["name", "age"], json.string)),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #("age", json.object([#("type", json.string("integer"))])),
        ]),
      ),
      #("additionalProperties", json.bool(False)),
    ])
}

pub fn object_with_optional_field_json_test() {
  assert sextant.to_json(user_with_email_schema())
    == json.object([
      schema_version(),
      #("required", json.array(["name"], json.string)),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #("email", json.object([#("type", json.string("string"))])),
        ]),
      ),
      #("additionalProperties", json.bool(False)),
    ])
}

pub fn enum_schema_json_test() {
  assert sextant.to_json(role_schema())
    == json.object([
      schema_version(),
      #("type", json.string("string")),
      #("enum", json.array(["admin", "member", "guest"], json.string)),
    ])
}

pub fn additional_properties_true_json_test() {
  let schema =
    user_schema()
    |> sextant.additional_properties(True)

  assert sextant.to_json(schema)
    == json.object([
      schema_version(),
      #("required", json.array(["name", "age"], json.string)),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #("age", json.object([#("type", json.string("integer"))])),
        ]),
      ),
      // Doesn't contain `additionalProperties` when True
    ])
}

pub fn default_object_has_additional_properties_false_test() {
  // Default behaviour should include additionalProperties: false
  assert sextant.to_json(user_schema())
    == json.object([
      schema_version(),
      #("required", json.array(["name", "age"], json.string)),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #("age", json.object([#("type", json.string("integer"))])),
        ]),
      ),
      #("additionalProperties", json.bool(False)),
    ])
}

pub fn nullable_schema_json_test() {
  assert sextant.to_json(sextant.optional(sextant.string()))
    == json.object([
      schema_version(),
      #(
        "oneOf",
        json.array(
          [
            json.object([#("type", json.string("null"))]),
            json.object([#("type", json.string("string"))]),
          ],
          fn(x) { x },
        ),
      ),
    ])
}

pub fn dict_schema_json_test() {
  assert sextant.to_json(sextant.dict(sextant.integer()))
    == json.object([
      schema_version(),
      #("type", json.string("object")),
      #(
        "additionalProperties",
        json.object([#("type", json.string("integer"))]),
      ),
    ])
}

pub fn one_of_schema_json_test() {
  let schema =
    sextant.one_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.to_json(schema)
    == json.object([
      schema_version(),
      #(
        "oneOf",
        json.array(
          [
            json.object([#("type", json.string("string"))]),
            json.object([#("type", json.string("integer"))]),
          ],
          fn(x) { x },
        ),
      ),
    ])
}

pub fn any_of_schema_json_test() {
  let schema =
    sextant.any_of(sextant.string() |> sextant.map(StringValue), [
      sextant.integer() |> sextant.map(IntValue),
    ])
  assert sextant.to_json(schema)
    == json.object([
      schema_version(),
      #(
        "anyOf",
        json.array(
          [
            json.object([#("type", json.string("string"))]),
            json.object([#("type", json.string("integer"))]),
          ],
          fn(x) { x },
        ),
      ),
    ])
}

pub fn string_min_length_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.min_length(5))
    == json.object([
      schema_version(),
      #("minLength", json.int(5)),
      #("type", json.string("string")),
    ])
}

pub fn string_max_length_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.max_length(100))
    == json.object([
      schema_version(),
      #("maxLength", json.int(100)),
      #("type", json.string("string")),
    ])
}

pub fn string_pattern_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.pattern("^[a-z]+$"))
    == json.object([
      schema_version(),
      #("pattern", json.string("^[a-z]+$")),
      #("type", json.string("string")),
    ])
}

pub fn string_format_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.format(sextant.Email))
    == json.object([
      schema_version(),
      #("format", json.string("email")),
      #("type", json.string("string")),
    ])
}

pub fn integer_min_json_test() {
  assert sextant.to_json(sextant.integer() |> sextant.int_min(0))
    == json.object([
      schema_version(),
      #("minimum", json.int(0)),
      #("type", json.string("integer")),
    ])
}

pub fn integer_max_json_test() {
  assert sextant.to_json(sextant.integer() |> sextant.int_max(100))
    == json.object([
      schema_version(),
      #("maximum", json.int(100)),
      #("type", json.string("integer")),
    ])
}

pub fn integer_exclusive_min_json_test() {
  assert sextant.to_json(sextant.integer() |> sextant.int_exclusive_min(0))
    == json.object([
      schema_version(),
      #("exclusiveMinimum", json.int(0)),
      #("type", json.string("integer")),
    ])
}

pub fn integer_exclusive_max_json_test() {
  assert sextant.to_json(sextant.integer() |> sextant.int_exclusive_max(100))
    == json.object([
      schema_version(),
      #("exclusiveMaximum", json.int(100)),
      #("type", json.string("integer")),
    ])
}

pub fn integer_multiple_of_json_test() {
  assert sextant.to_json(sextant.integer() |> sextant.int_multiple_of(5))
    == json.object([
      schema_version(),
      #("multipleOf", json.int(5)),
      #("type", json.string("integer")),
    ])
}

pub fn float_min_json_test() {
  assert sextant.to_json(sextant.number() |> sextant.float_min(0.0))
    == json.object([
      schema_version(),
      #("minimum", json.float(0.0)),
      #("type", json.string("number")),
    ])
}

pub fn float_max_json_test() {
  assert sextant.to_json(sextant.number() |> sextant.float_max(100.0))
    == json.object([
      schema_version(),
      #("maximum", json.float(100.0)),
      #("type", json.string("number")),
    ])
}

pub fn title_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.title("User Name"))
    == json.object([
      schema_version(),
      #("title", json.string("User Name")),
      #("type", json.string("string")),
    ])
}

pub fn description_json_test() {
  assert sextant.to_json(sextant.string() |> sextant.describe("A user name"))
    == json.object([
      schema_version(),
      #("description", json.string("A user name")),
      #("type", json.string("string")),
    ])
}

pub fn examples_json_test() {
  assert sextant.to_json(
      sextant.string()
      |> sextant.examples([json.string("foo"), json.string("bar")]),
    )
    == json.object([
      schema_version(),
      #(
        "examples",
        json.array([json.string("foo"), json.string("bar")], fn(x) { x }),
      ),
      #("type", json.string("string")),
    ])
}

pub fn default_json_test() {
  assert sextant.to_json(
      sextant.string() |> sextant.default(json.string("default")),
    )
    == json.object([
      schema_version(),
      #("default", json.string("default")),
      #("type", json.string("string")),
    ])
}

pub fn nested_object_json_test() {
  assert sextant.to_json(person_schema())
    == json.object([
      schema_version(),
      #("required", json.array(["name", "address"], json.string)),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
          #(
            "address",
            json.object([
              #("required", json.array(["city", "zip"], json.string)),
              #("type", json.string("object")),
              #(
                "properties",
                json.object([
                  #("city", json.object([#("type", json.string("string"))])),
                  #("zip", json.object([#("type", json.string("string"))])),
                ]),
              ),
              #("additionalProperties", json.bool(False)),
            ]),
          ),
        ]),
      ),
      #("additionalProperties", json.bool(False)),
    ])
}

pub fn uuid_format_json_test() {
  assert sextant.to_json(sextant.uuid())
    == json.object([
      schema_version(),
      #("format", json.string("uuid")),
      #("type", json.string("string")),
    ])
}

pub fn timestamp_format_json_test() {
  assert sextant.to_json(sextant.timestamp())
    == json.object([
      schema_version(),
      #("format", json.string("date-time")),
      #("type", json.string("string")),
    ])
}

pub fn uri_format_json_test() {
  assert sextant.to_json(sextant.uri())
    == json.object([
      schema_version(),
      #("format", json.string("uri")),
      #("type", json.string("string")),
    ])
}

// ---------------------------------------------------------------------------
// Error Formatting Tests
// ---------------------------------------------------------------------------

pub fn error_to_string_type_error_test() {
  let error = sextant.TypeError("String", "Int", ["user", "name"])
  let str = sextant.error_to_string(error)
  assert string.contains(str, "Expected String")
  assert string.contains(str, "got Int")
  assert string.contains(str, "user.name")
}

pub fn error_to_string_missing_field_test() {
  let error = sextant.MissingField("email", ["user"])
  let str = sextant.error_to_string(error)
  assert string.contains(str, "Missing required field 'email'")
  assert string.contains(str, "user")
}

pub fn error_to_string_constraint_test() {
  let error =
    sextant.ConstraintError(
      sextant.StringViolation(sextant.StringTooShort(5, 2)),
      ["name"],
    )
  let str = sextant.error_to_string(error)
  assert string.contains(str, "String too short")
  assert string.contains(str, "minimum: 5")
  assert string.contains(str, "got: 2")
}

// ---------------------------------------------------------------------------
// Const Value Tests
// ---------------------------------------------------------------------------

pub fn const_value_string_valid_test() {
  let schema = sextant.string() |> sextant.const_value("fixed", json.string)
  assert sextant.run(dynamic.string("fixed"), schema) == Ok("fixed")
}

pub fn const_value_string_invalid_test() {
  let schema = sextant.string() |> sextant.const_value("fixed", json.string)
  assert sextant.run(dynamic.string("other"), schema)
    == Error([sextant.ConstMismatch("\"fixed\"", "\"other\"", [])])
}

pub fn const_value_int_valid_test() {
  let schema = sextant.integer() |> sextant.const_value(42, json.int)
  assert sextant.run(dynamic.int(42), schema) == Ok(42)
}

pub fn const_value_int_invalid_test() {
  let schema = sextant.integer() |> sextant.const_value(42, json.int)
  assert sextant.run(dynamic.int(99), schema)
    == Error([sextant.ConstMismatch("42", "99", [])])
}

pub fn const_value_bool_valid_test() {
  let schema = sextant.boolean() |> sextant.const_value(True, json.bool)
  assert sextant.run(dynamic.bool(True), schema) == Ok(True)
}

pub fn const_value_bool_invalid_test() {
  let schema = sextant.boolean() |> sextant.const_value(True, json.bool)
  assert sextant.run(dynamic.bool(False), schema)
    == Error([sextant.ConstMismatch("True", "False", [])])
}

pub fn const_value_type_error_test() {
  // Type error should be returned instead of const mismatch
  let schema = sextant.string() |> sextant.const_value("fixed", json.string)
  let result = sextant.run(dynamic.int(123), schema)
  let assert Error([sextant.TypeError("String", _, [])]) = result
}

pub fn const_value_schema_json_test() {
  let schema = sextant.string() |> sextant.const_value("api_v1", json.string)
  assert sextant.to_json(schema)
    == json.object([
      #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
      #("const", json.string("api_v1")),
    ])
}

pub fn const_value_int_schema_json_test() {
  let schema = sextant.integer() |> sextant.const_value(42, json.int)
  assert sextant.to_json(schema)
    == json.object([
      #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
      #("const", json.int(42)),
    ])
}

pub fn error_to_string_const_mismatch_test() {
  let error = sextant.ConstMismatch("\"expected\"", "\"actual\"", ["field"])
  let str = sextant.error_to_string(error)
  assert string.contains(str, "Expected const value")
  assert string.contains(str, "\"expected\"")
  assert string.contains(str, "\"actual\"")
  assert string.contains(str, "field")
}
