# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::UserSyncSources do
  fab!(:user)
  fab!(:other_user, :user)

  it "loads selected profile columns once and skips blank values when mapping to Salesforce" do
    user.user_profile.update!(bio_raw: "I build **communities**.", website: "https://example.com")
    other_user.user_profile.update!(bio_raw: "", website: "")
    mappings = [
      { "source" => "last", "destination" => "LastName", "policy" => "keep" },
      { "source" => "bio", "destination" => "Description", "policy" => "overwrite" },
      { "source" => "website", "destination" => "Website", "policy" => "overwrite" },
    ]
    data = nil
    queries = track_sql_queries { data = described_class.new(mappings, [user, other_user]) }
    expect(queries.count { |query| query.include?('FROM "user_profiles"') }).to eq(1)
    expect(queries.grep(/FROM "user_stats"/)).to be_empty
    expect(
      track_sql_queries do
        data.value("bio", user)
        data.value("website", other_user)
      end,
    ).to be_empty
    fields =
      {
        "Email" => "email",
        "LastName" => "string",
        "Description" => "textarea",
        "Website" => "url",
      }.map do |name, type|
        { "name" => name, "type" => type, "createable" => true, "updateable" => true }
      end
    configuration = { "object" => "Contact", "mappings" => mappings }
    Salesforce::ConfiguredUserSync.validate_mappings!(configuration, fields)
    sync =
      Salesforce::ConfiguredUserSync.new(configuration, user, api: Object.new, source_data: data)
    expect(sync.mapped_values(fields, nil)).to include(
      "Description" => "I build **communities**.",
      "Website" => "https://example.com",
    )
    empty_sync =
      Salesforce::ConfiguredUserSync.new(
        configuration,
        other_user,
        api: Object.new,
        source_data: data,
      )
    expect(
      empty_sync.mapped_values(
        fields,
        { "LastName" => "Existing", "Website" => "https://existing.example" },
      ),
    ).to eq({})
  end

  it "loads selected stored totals once for all users and converts seconds to minutes" do
    user.user_stat.update!(
      time_read: 125,
      posts_read_count: 21,
      topics_entered: 8,
      likes_given: 4,
      likes_received: 6,
      days_visited: 3,
    )
    sources = %w[read_time posts_read topics_entered likes_given likes_received days_visited]
    data = nil
    queries =
      track_sql_queries do
        data =
          described_class.new(sources.map { |source| { "source" => source } }, [user, other_user])
      end
    expect(queries.count { |query| query.include?('FROM "user_stats"') }).to eq(1)
    expect(queries.grep(/FROM "user_custom_fields"/)).to be_empty
    values = nil
    expect(
      track_sql_queries { values = sources.map { |source| data.value(source, user) } },
    ).to be_empty
    expect(values).to eq([2.08, 21, 8, 4, 6, 3])
    expect(data.value("read_time", other_user)).to eq(0)
  end

  it "loads only configured selected custom fields and preserves their types" do
    text = Fabricate(:user_field, name: "Job title")
    confirm = Fabricate(:user_field, field_type: "confirm")
    date = Fabricate(:user_field, field_type: "date")
    multi = Fabricate(:user_field, field_type: "multiselect")
    user.custom_fields["user_field_#{text.id}"] = "Engineer"
    user.custom_fields["user_field_#{confirm.id}"] = "false"
    user.custom_fields["user_field_#{date.id}"] = "2026-10-26"
    user.custom_fields["user_field_#{multi.id}"] = %w[One Two]
    user.custom_fields["internal_token"] = "private"
    user.save_custom_fields
    sources = [text, confirm, date, multi].map { |field| "user_field_#{field.id}" }
    data = nil
    queries =
      track_sql_queries do
        data =
          described_class.new(sources.map { |source| { "source" => source } }, [user, other_user])
      end
    expect(queries.count { |query| query.include?('FROM "user_custom_fields"') }).to eq(1)
    expect(queries.grep(/FROM "user_stats"/)).to be_empty
    expect(sources.map { |source| data.value(source, user) }).to eq(
      ["Engineer", false, Date.new(2026, 10, 26), %w[One Two]],
    )
    expect(data.value(sources.first, other_user)).to be_nil
    expect { data.value("internal_token", user) }.to raise_error(Discourse::InvalidParameters)
    text.update!(name: "Role")
    expect(described_class.custom_sources).to include(id: sources.first, name: "Role", type: "text")
    expect(described_class.custom_sources.map { |source| source[:id] }).not_to include(
      "internal_token",
    )
  end

  it "converts custom values for Salesforce and rejects deleted or incompatible sources" do
    multi = Fabricate(:user_field, field_type: "multiselect")
    confirm = Fabricate(:user_field, field_type: "confirm")
    date = Fabricate(:user_field, field_type: "date")
    user.custom_fields["user_field_#{multi.id}"] = %w[One Two]
    user.custom_fields["user_field_#{confirm.id}"] = "false"
    user.custom_fields["user_field_#{date.id}"] = "2026-10-26"
    user.save_custom_fields
    mappings = [
      { "source" => "last", "destination" => "LastName", "policy" => "keep" },
      {
        "source" => "user_field_#{multi.id}",
        "destination" => "Choices__c",
        "policy" => "overwrite",
      },
      {
        "source" => "user_field_#{confirm.id}",
        "destination" => "Confirmed__c",
        "policy" => "overwrite",
      },
      { "source" => "user_field_#{date.id}", "destination" => "Date__c", "policy" => "overwrite" },
    ]
    fields =
      {
        "Email" => "email",
        "LastName" => "string",
        "Choices__c" => "multipicklist",
        "Confirmed__c" => "boolean",
        "Date__c" => "datetime",
      }.map do |name, type|
        { "name" => name, "type" => type, "createable" => true, "updateable" => true }
      end
    configuration = { "object" => "Contact", "mappings" => mappings }
    Salesforce::ConfiguredUserSync.validate_mappings!(configuration, fields)
    sync = Salesforce::ConfiguredUserSync.new(configuration, user, api: Object.new)
    expect(sync.mapped_values(fields, nil)).to include(
      "Choices__c" => "One;Two",
      "Confirmed__c" => false,
      "Date__c" => "2026-10-26T00:00:00Z",
    )
    fields.find { |field| field["name"] == "Choices__c" }["type"] = "string"
    expect(sync.mapped_values(fields, nil)["Choices__c"]).to eq("One, Two")
    fields.find { |field| field["name"] == "Confirmed__c" }["type"] = "string"
    expect {
      Salesforce::ConfiguredUserSync.validate_mappings!(configuration, fields)
    }.to raise_error(Discourse::InvalidParameters)
    fields.find { |field| field["name"] == "Confirmed__c" }["type"] = "boolean"
    multi.destroy!
    expect {
      Salesforce::ConfiguredUserSync.validate_mappings!(configuration, fields)
    }.to raise_error(Discourse::InvalidParameters)
  end
end
