import gleam/dynamic
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sextant

// ---------------------------------------------------------------------------
// Domain Types
// ---------------------------------------------------------------------------

type Priority {
  Low
  Medium
  High
  Critical
}

type Status {
  Draft
  Active
  Completed
  Archived
}

type Tag {
  Tag(name: String, colour: String)
}

type Address {
  Address(street: String, city: String, zip: String, country: Option(String))
}

type Task {
  Task(
    id: String,
    title: String,
    description: Option(String),
    priority: Priority,
    status: Status,
    tags: List(Tag),
    assignee: Option(Assignee),
    estimated_hours: Option(Float),
    subtasks: List(String),
  )
}

type Assignee {
  Person(name: String, email: String, address: Option(Address))
  Team(name: String, member_count: Int)
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

fn priority_schema() -> sextant.JsonSchema(Priority) {
  sextant.enum(#("low", Low), [
    #("medium", Medium),
    #("high", High),
    #("critical", Critical),
  ])
  |> sextant.describe("Task priority level")
}

fn status_schema() -> sextant.JsonSchema(Status) {
  sextant.enum(#("draft", Draft), [
    #("active", Active),
    #("completed", Completed),
    #("archived", Archived),
  ])
  |> sextant.describe("Current task status")
}

fn tag_schema() -> sextant.JsonSchema(Tag) {
  use name <- sextant.field(
    "name",
    sextant.string()
      |> sextant.min_length(1)
      |> sextant.max_length(50),
  )
  use colour <- sextant.field(
    "colour",
    sextant.string()
      |> sextant.pattern("^#[0-9a-fA-F]{6}$")
      |> sextant.describe("Hex colour code (e.g., #ff5733)"),
  )
  sextant.success(Tag(name:, colour:))
}

fn address_schema() -> sextant.JsonSchema(Address) {
  use street <- sextant.field("street", sextant.string())
  use city <- sextant.field("city", sextant.string())
  use zip <- sextant.field(
    "zip",
    sextant.string()
      |> sextant.pattern("^[0-9]{5}(-[0-9]{4})?$")
      |> sextant.describe("US ZIP code (e.g., 12345 or 12345-6789)"),
  )
  use country <- sextant.optional_field("country", sextant.string())
  sextant.success(Address(street:, city:, zip:, country:))
}

fn person_schema() -> sextant.JsonSchema(Assignee) {
  use name <- sextant.field(
    "name",
    sextant.string()
      |> sextant.min_length(1)
      |> sextant.max_length(100),
  )
  use email <- sextant.field(
    "email",
    sextant.string()
      |> sextant.format(sextant.Email)
      |> sextant.describe("Work email address"),
  )
  use address <- sextant.optional_field("address", address_schema())
  sextant.success(Person(name:, email:, address:))
}

fn team_schema() -> sextant.JsonSchema(Assignee) {
  use name <- sextant.field(
    "name",
    sextant.string()
      |> sextant.min_length(1)
      |> sextant.title("Team Name"),
  )
  use member_count <- sextant.field(
    "member_count",
    sextant.integer()
      |> sextant.int_min(1)
      |> sextant.int_max(1000)
      |> sextant.describe("Number of team members"),
  )
  sextant.success(Team(name:, member_count:))
}

fn assignee_schema() -> sextant.JsonSchema(Assignee) {
  sextant.one_of(person_schema(), [team_schema()])
  |> sextant.describe("Either a person or a team")
}

fn task_schema() -> sextant.JsonSchema(Task) {
  use id <- sextant.field(
    "id",
    sextant.string()
      |> sextant.format(sextant.Uuid)
      |> sextant.describe("Unique task identifier"),
  )
  use title <- sextant.field(
    "title",
    sextant.string()
      |> sextant.min_length(1)
      |> sextant.max_length(200)
      |> sextant.title("Task Title")
      |> sextant.examples([
        json.string("Fix login bug"),
        json.string("Update docs"),
      ]),
  )
  use description <- sextant.optional_field(
    "description",
    sextant.string()
      |> sextant.max_length(5000),
  )
  use priority <- sextant.field("priority", priority_schema())
  use status <- sextant.field("status", status_schema())
  use tags <- sextant.field(
    "tags",
    sextant.array(of: tag_schema())
      |> sextant.max_items(10)
      |> sextant.describe("Task tags for categorization"),
  )
  use assignee <- sextant.optional_field("assignee", assignee_schema())
  use estimated_hours <- sextant.optional_field(
    "estimated_hours",
    sextant.number()
      |> sextant.float_min(0.25)
      |> sextant.float_max(1000.0)
      |> sextant.describe("Estimated hours to complete"),
  )
  use subtasks <- sextant.field(
    "subtasks",
    sextant.array(of: sextant.string() |> sextant.min_length(1))
      |> sextant.unique_items()
      |> sextant.describe("List of subtask descriptions"),
  )
  sextant.success(Task(
    id:,
    title:,
    description:,
    priority:,
    status:,
    tags:,
    assignee:,
    estimated_hours:,
    subtasks:,
  ))
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() {
  io.println("=== Task Schema (JSON Schema 2020-12) ===\n")

  let schema_json = sextant.to_json(task_schema()) |> json.to_string
  io.println(schema_json)

  io.println("\n\n=== Validating Sample Data ===\n")

  // Valid task data
  let valid_task =
    make_task_data(
      id: "550e8400-e29b-41d4-a716-446655440000",
      title: "Implement user authentication",
      description: Some("Add OAuth2 support for Google and GitHub"),
      priority: "high",
      status: "active",
      tags: [#("backend", "#3498db"), #("security", "#e74c3c")],
      assignee: Some(PersonData(
        name: "Alice Smith",
        email: "alice@example.com",
        address: None,
      )),
      estimated_hours: Some(16.0),
      subtasks: ["Research OAuth2 providers", "Implement token refresh"],
    )

  case sextant.run(valid_task, task_schema()) {
    Ok(task) -> {
      io.println("Valid task:")
      io.println("  ID: " <> task.id)
      io.println("  Title: " <> task.title)
      io.println("  Priority: " <> priority_to_string(task.priority))
      io.println("  Status: " <> status_to_string(task.status))
    }
    Error(errors) -> {
      io.println("Validation failed:")
      io.println(list.map(errors, sextant.error_to_string) |> string.join("\n"))
    }
  }

  io.println("\n--- Testing Invalid Data ---\n")

  // Invalid: title too long, invalid priority, negative hours
  let invalid_task =
    make_task_data(
      id: "not-a-uuid",
      title: "x",
      description: None,
      priority: "urgent",
      status: "active",
      tags: [#("", "#invalid")],
      assignee: None,
      estimated_hours: Some(-5.0),
      subtasks: [],
    )

  // Enable format validation to catch the invalid UUID
  let opts = sextant.Options(validate_formats: True)

  case sextant.run_with_options(invalid_task, task_schema(), opts) {
    Ok(_) -> io.println("Unexpectedly valid!")
    Error(errors) -> {
      io.println("Validation errors (expected):")
      io.println(list.map(errors, sextant.error_to_string) |> string.join("\n"))
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type AssigneeData {
  PersonData(name: String, email: String, address: Option(Address))
  TeamData(name: String, member_count: Int)
}

fn make_task_data(
  id id: String,
  title title: String,
  description description: Option(String),
  priority priority: String,
  status status: String,
  tags tags: List(#(String, String)),
  assignee assignee: Option(AssigneeData),
  estimated_hours estimated_hours: Option(Float),
  subtasks subtasks: List(String),
) -> dynamic.Dynamic {
  let tag_data =
    tags
    |> list.map(fn(t) {
      dynamic.properties([
        #(dynamic.string("name"), dynamic.string(t.0)),
        #(dynamic.string("colour"), dynamic.string(t.1)),
      ])
    })

  let base_fields = [
    #(dynamic.string("id"), dynamic.string(id)),
    #(dynamic.string("title"), dynamic.string(title)),
    #(dynamic.string("priority"), dynamic.string(priority)),
    #(dynamic.string("status"), dynamic.string(status)),
    #(dynamic.string("tags"), dynamic.list(tag_data)),
    #(
      dynamic.string("subtasks"),
      dynamic.list(list.map(subtasks, dynamic.string)),
    ),
  ]

  let with_description = case description {
    Some(d) -> [
      #(dynamic.string("description"), dynamic.string(d)),
      ..base_fields
    ]
    None -> base_fields
  }

  let with_hours = case estimated_hours {
    Some(h) -> [
      #(dynamic.string("estimated_hours"), dynamic.float(h)),
      ..with_description
    ]
    None -> with_description
  }

  let with_assignee = case assignee {
    Some(PersonData(name, email, _address)) -> [
      #(
        dynamic.string("assignee"),
        dynamic.properties([
          #(dynamic.string("name"), dynamic.string(name)),
          #(dynamic.string("email"), dynamic.string(email)),
        ]),
      ),
      ..with_hours
    ]
    Some(TeamData(name, count)) -> [
      #(
        dynamic.string("assignee"),
        dynamic.properties([
          #(dynamic.string("name"), dynamic.string(name)),
          #(dynamic.string("member_count"), dynamic.int(count)),
        ]),
      ),
      ..with_hours
    ]
    None -> with_hours
  }

  dynamic.properties(with_assignee)
}

fn priority_to_string(p: Priority) -> String {
  case p {
    Low -> "Low"
    Medium -> "Medium"
    High -> "High"
    Critical -> "Critical"
  }
}

fn status_to_string(s: Status) -> String {
  case s {
    Draft -> "Draft"
    Active -> "Active"
    Completed -> "Completed"
    Archived -> "Archived"
  }
}
