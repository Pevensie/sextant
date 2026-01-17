/// Property-based tests for sextant JSON Schema library.
///
/// These tests verify invariants that should hold for all inputs,
/// using random value generation and shrinking.
import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import sextant

// ---------------------------------------------------------------------------
// Primitive Schema Property Tests
// ---------------------------------------------------------------------------

/// Property: Any string value should decode successfully with string()
pub fn string_decodes_any_string__test() {
  use s <- qcheck.given(qcheck.string())
  let schema = sextant.string()
  let result = sextant.run(dynamic.string(s), schema)
  assert result == Ok(s)
}

/// Property: Any integer should decode successfully with integer()
pub fn integer_decodes_any_int__test() {
  use n <- qcheck.given(qcheck.uniform_int())
  let schema = sextant.integer()
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(n)
}

/// Property: Any float should decode successfully with number()
pub fn number_decodes_any_float__test() {
  use f <- qcheck.given(qcheck.float())
  let schema = sextant.number()
  let result = sextant.run(dynamic.float(f), schema)
  assert result == Ok(f)
}

/// Property: Any boolean should decode successfully with boolean()
pub fn boolean_decodes_any_bool__test() {
  use b <- qcheck.given(qcheck.bool())
  let schema = sextant.boolean()
  let result = sextant.run(dynamic.bool(b), schema)
  assert result == Ok(b)
}

/// Property: Integers passed to number() should convert to float
pub fn number_accepts_integers_as_floats__test() {
  use n <- qcheck.given(qcheck.uniform_int())
  let schema = sextant.number()
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(int.to_float(n))
}

// ---------------------------------------------------------------------------
// String Constraint Property Tests
// ---------------------------------------------------------------------------

/// Property: Strings with length >= min should pass min_length
pub fn min_length_accepts_valid_strings__test() {
  use #(min, extra) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 50),
    qcheck.bounded_int(0, 50),
  ))
  let s = string.repeat("x", min + extra)
  let schema = sextant.string() |> sextant.min_length(min)
  let result = sextant.run(dynamic.string(s), schema)
  assert result == Ok(s)
}

/// Property: Strings with length < min should fail min_length
pub fn min_length_rejects_short_strings__test() {
  use min <- qcheck.given(qcheck.bounded_int(1, 50))
  // Generate string shorter than min (0 to min-1 chars)
  let len = int.max(0, min - 1)
  let s = string.repeat("x", len)
  let schema = sextant.string() |> sextant.min_length(min)
  let result = sextant.run(dynamic.string(s), schema)
  assert result |> result.is_error
}

/// Property: Strings with length <= max should pass max_length
pub fn max_length_accepts_valid_strings__test() {
  use max <- qcheck.given(qcheck.bounded_int(0, 100))
  // Generate string of length 0 to max
  let s = string.repeat("x", max)
  let schema = sextant.string() |> sextant.max_length(max)
  let result = sextant.run(dynamic.string(s), schema)
  assert result == Ok(s)
}

/// Property: Strings with length > max should fail max_length
pub fn max_length_rejects_long_strings__test() {
  use #(max, extra) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 50),
    qcheck.bounded_int(1, 50),
  ))
  let s = string.repeat("x", max + extra)
  let schema = sextant.string() |> sextant.max_length(max)
  let result = sextant.run(dynamic.string(s), schema)
  assert result |> result.is_error
}

// ---------------------------------------------------------------------------
// Integer Constraint Property Tests
// ---------------------------------------------------------------------------

/// Property: Integers >= min should pass int_min
pub fn int_min_accepts_valid_integers__test() {
  use #(min, offset) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-1000, 1000),
    qcheck.bounded_int(0, 1000),
  ))
  let n = min + offset
  let schema = sextant.integer() |> sextant.int_min(min)
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(n)
}

/// Property: Integers < min should fail int_min
pub fn int_min_rejects_small_integers__test() {
  use #(min, offset) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-1000, 1000),
    qcheck.bounded_int(1, 1000),
  ))
  let n = min - offset
  let schema = sextant.integer() |> sextant.int_min(min)
  let result = sextant.run(dynamic.int(n), schema)
  assert result |> result.is_error
}

/// Property: Integers <= max should pass int_max
pub fn int_max_accepts_valid_integers__test() {
  use #(max, offset) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-1000, 1000),
    qcheck.bounded_int(0, 1000),
  ))
  let n = max - offset
  let schema = sextant.integer() |> sextant.int_max(max)
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(n)
}

/// Property: Integers > max should fail int_max
pub fn int_max_rejects_large_integers__test() {
  use #(max, offset) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-1000, 1000),
    qcheck.bounded_int(1, 1000),
  ))
  let n = max + offset
  let schema = sextant.integer() |> sextant.int_max(max)
  let result = sextant.run(dynamic.int(n), schema)
  assert result |> result.is_error
}

/// Property: Multiples of m should pass int_multiple_of
pub fn int_multiple_of_accepts_multiples__test() {
  use #(multiple, factor) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(1, 100),
    qcheck.bounded_int(-100, 100),
  ))
  let n = multiple * factor
  let schema = sextant.integer() |> sextant.int_multiple_of(multiple)
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(n)
}

/// Property: Non-multiples should fail int_multiple_of (when offset != 0)
pub fn int_multiple_of_rejects_non_multiples__test() {
  use #(multiple, factor, offset) <- qcheck.given(qcheck.tuple3(
    qcheck.bounded_int(2, 100),
    qcheck.bounded_int(-100, 100),
    qcheck.bounded_int(1, 99),
  ))
  // Ensure offset is not a multiple of the multiple
  let actual_offset = case offset % multiple {
    0 -> 1
    x -> x
  }
  let n = multiple * factor + actual_offset
  let schema = sextant.integer() |> sextant.int_multiple_of(multiple)
  let result = sextant.run(dynamic.int(n), schema)
  assert result |> result.is_error
}

// ---------------------------------------------------------------------------
// Array Constraint Property Tests
// ---------------------------------------------------------------------------

/// Property: Arrays with length >= min should pass min_items
pub fn min_items_accepts_valid_arrays__test() {
  use #(min, extra) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 20),
    qcheck.bounded_int(0, 20),
  ))
  let items = list.repeat(1, min + extra)
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.min_items(min)
  let result = sextant.run(data, schema)
  assert result == Ok(items)
}

/// Property: Arrays with length < min should fail min_items
pub fn min_items_rejects_short_arrays__test() {
  use min <- qcheck.given(qcheck.bounded_int(1, 20))
  let len = int.max(0, min - 1)
  let items = list.repeat(1, len)
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.min_items(min)
  let result = sextant.run(data, schema)
  assert result |> result.is_error
}

/// Property: Arrays with length <= max should pass max_items
pub fn max_items_accepts_valid_arrays__test() {
  use max <- qcheck.given(qcheck.bounded_int(0, 30))
  let items = list.repeat(1, max)
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.max_items(max)
  let result = sextant.run(data, schema)
  assert result == Ok(items)
}

/// Property: Arrays with length > max should fail max_items
pub fn max_items_rejects_long_arrays__test() {
  use #(max, extra) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 20),
    qcheck.bounded_int(1, 20),
  ))
  let items = list.repeat(1, max + extra)
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.max_items(max)
  let result = sextant.run(data, schema)
  assert result |> result.is_error
}

/// Property: Arrays with all unique items should pass unique_items
pub fn unique_items_accepts_unique_arrays__test() {
  use n <- qcheck.given(qcheck.bounded_int(0, 20))
  // Create array [0, 1, 2, ..., n-1] which is always unique
  let items = list.range(0, n - 1)
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.unique_items()
  let result = sextant.run(data, schema)
  assert result == Ok(items)
}

/// Property: Arrays with duplicates should fail unique_items
pub fn unique_items_rejects_duplicate_arrays__test() {
  use n <- qcheck.given(qcheck.bounded_int(2, 20))
  // Create array with at least one duplicate: [1, 1, 2, 3, ...]
  let items = [1, 1, ..list.range(2, n)]
  let data = dynamic.list(list.map(items, dynamic.int))
  let schema = sextant.array(of: sextant.integer()) |> sextant.unique_items()
  let result = sextant.run(data, schema)
  assert result |> result.is_error
}

// ---------------------------------------------------------------------------
// Compound Type Property Tests
// ---------------------------------------------------------------------------

/// Property: nullable() should accept null values
pub fn nullable_accepts_null__test() {
  // Just verify the behaviour (not property-based, but ensures correctness)
  let schema = sextant.optional(sextant.string())
  let result = sextant.run(dynamic.nil(), schema)
  assert result == Ok(None)
}

/// Property: nullable() should accept non-null values
pub fn nullable_accepts_values__test() {
  use s <- qcheck.given(qcheck.string())
  let schema = sextant.optional(sextant.string())
  let result = sextant.run(dynamic.string(s), schema)
  assert result == Ok(Some(s))
}

/// Property: dict() should decode string-keyed objects
pub fn dict_decodes_string_int_pairs__test() {
  // Generate a list of key-value pairs
  use pairs <- qcheck.given(
    qcheck.list_from(qcheck.tuple2(
      qcheck.non_empty_string(),
      qcheck.uniform_int(),
    )),
  )
  // Build dynamic object from pairs
  let data =
    dynamic.properties(
      list.map(pairs, fn(pair) {
        #(dynamic.string(pair.0), dynamic.int(pair.1))
      }),
    )
  let schema = sextant.dict(sextant.integer())
  let result = sextant.run(data, schema)
  // Result should be Ok with a dict
  assert result |> result.is_ok
}

// ---------------------------------------------------------------------------
// Error Accumulation Property Tests
// ---------------------------------------------------------------------------

/// Property: Multiple constraint violations should all be reported
pub fn error_accumulation_reports_all_violations__test() {
  // Value is < 0 and not a multiple of 7
  let value = -1
  let schema =
    sextant.integer()
    |> sextant.int_min(0)
    |> sextant.int_multiple_of(7)

  let result = sextant.run(dynamic.int(value), schema)
  let assert Error(errors) = result
  // Should have exactly 2 errors
  assert list.length(errors) == 2
}

/// Property: Type errors prevent constraint checking
pub fn type_error_prevents_constraint_errors__test() {
  use min <- qcheck.given(qcheck.bounded_int(1, 100))
  let schema = sextant.string() |> sextant.min_length(min)
  // Pass an integer instead of string
  let result = sextant.run(dynamic.int(42), schema)
  let assert Error(errors) = result
  // Should only have 1 error (type error), not constraint errors
  assert list.length(errors) == 1
  case errors {
    [sextant.TypeError(_, _, _)] -> Nil
    _ -> panic as "Expected a single TypeError"
  }
}

// ---------------------------------------------------------------------------
// const_value Property Tests
// ---------------------------------------------------------------------------

/// Property: const_value accepts only the exact value
pub fn const_value_accepts_exact_match__test() {
  use n <- qcheck.given(qcheck.uniform_int())
  let schema = sextant.integer() |> sextant.const_value(n, json.int)
  let result = sextant.run(dynamic.int(n), schema)
  assert result == Ok(n)
}

/// Property: const_value rejects different values
pub fn const_value_rejects_different_values__test() {
  use #(const_val, other_val) <- qcheck.given(qcheck.tuple2(
    qcheck.uniform_int(),
    qcheck.uniform_int(),
  ))
  // Skip if they happen to be equal
  case const_val == other_val {
    True -> Nil
    False -> {
      let schema = sextant.integer() |> sextant.const_value(const_val, json.int)
      let result = sextant.run(dynamic.int(other_val), schema)
      assert result |> result.is_error
    }
  }
}

// ---------------------------------------------------------------------------
// Schema JSON Generation Property Tests
// ---------------------------------------------------------------------------

/// Property: Generated schema JSON should always contain $schema field
pub fn schema_json_contains_schema_field__test() {
  // Test with string schema
  let schema = sextant.string()
  let json_str = sextant.to_json(schema) |> json.to_string
  assert string.contains(json_str, "$schema")
  assert string.contains(
    json_str,
    "https://json-schema.org/draft/2020-12/schema",
  )
}

/// Property: String schema with constraints should include those constraints
pub fn string_schema_json_includes_constraints__test() {
  use #(min, max) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 50),
    qcheck.bounded_int(51, 100),
  ))
  let schema =
    sextant.string()
    |> sextant.min_length(min)
    |> sextant.max_length(max)
  let json_str = sextant.to_json(schema) |> json.to_string
  assert string.contains(json_str, "minLength")
  assert string.contains(json_str, "maxLength")
  assert string.contains(json_str, int.to_string(min))
  assert string.contains(json_str, int.to_string(max))
}

/// Property: Integer schema with constraints should include those constraints
pub fn integer_schema_json_includes_constraints__test() {
  use #(min, max) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-100, 0),
    qcheck.bounded_int(1, 100),
  ))
  let schema =
    sextant.integer()
    |> sextant.int_min(min)
    |> sextant.int_max(max)
  let json_str = sextant.to_json(schema) |> json.to_string
  assert string.contains(json_str, "minimum")
  assert string.contains(json_str, "maximum")
}

/// Property: Array schema should include items definition
pub fn array_schema_json_includes_items__test() {
  let schema = sextant.array(of: sextant.string())
  let json_str = sextant.to_json(schema) |> json.to_string
  assert string.contains(json_str, "\"type\":\"array\"")
  assert string.contains(json_str, "\"items\"")
}

/// Property: const_value schema should produce const in JSON
pub fn const_value_schema_json_includes_const__test() {
  use n <- qcheck.given(qcheck.bounded_int(-1000, 1000))
  let schema = sextant.integer() |> sextant.const_value(n, json.int)
  let json_str = sextant.to_json(schema) |> json.to_string
  assert string.contains(json_str, "\"const\"")
  assert string.contains(json_str, int.to_string(n))
}
