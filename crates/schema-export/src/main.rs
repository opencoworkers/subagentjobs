fn main() {
    let schema = schemars::schema_for!(schema::TaskSession);
    println!("{}", serde_json::to_string_pretty(&schema).unwrap());
}
