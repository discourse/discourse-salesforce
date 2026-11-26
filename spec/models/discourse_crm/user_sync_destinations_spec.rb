# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::UserSyncDestinations do
  fab!(:user) { Fabricate(:user, name: "Ada Lovelace") }
  fab!(:text_field) { Fabricate(:user_field, name: "Phone", field_type: "text") }
  fab!(:date_field) { Fabricate(:user_field, name: "Renewal", field_type: "date") }
  fab!(:confirm_field) { Fabricate(:user_field, name: "Customer", field_type: "confirm") }
  fab!(:dropdown_field) do
    Fabricate(:user_field, name: "Tier", field_type: "dropdown").tap do |field|
      field.user_field_options.create!(value: "Gold")
      field.user_field_options.create!(value: "Silver")
    end
  end
  fab!(:multiselect_field) do
    Fabricate(:user_field, name: "Products", field_type: "multiselect").tap do |field|
      field.user_field_options.create!(value: "Forum")
      field.user_field_options.create!(value: "Chat")
    end
  end

  def mapping(destination, source: destination, policy: "overwrite")
    { "object" => "contact", "source" => source, "destination" => destination, "policy" => policy }
  end

  def write(mappings, properties)
    described_class.new.write(user, mappings, properties)
  end

  describe ".all" do
    it "lists built-in, user and custom fields with the types they accept" do
      UserCustomField.create!(user: user, name: "crm_region", value: "EU")

      text = %w[text number]
      expect(described_class.all).to include(
        { id: "name", name: "Name", type: "text", group: "details", accepts: text },
        { id: "bio", name: "Bio", type: "text", group: "details", accepts: text },
        {
          id: "user_field_#{text_field.id}",
          name: "Phone",
          type: "text",
          group: "custom",
          accepts: text,
        },
        {
          id: "user_field_#{date_field.id}",
          name: "Renewal",
          type: "date",
          group: "custom",
          accepts: %w[date],
        },
        {
          id: "user_field_#{confirm_field.id}",
          name: "Customer",
          type: "boolean",
          group: "custom",
          accepts: %w[boolean],
        },
        {
          id: "custom_field:crm_region",
          name: "crm_region",
          type: "text",
          group: "custom",
          accepts: text,
        },
      )
    end
  end

  describe "#write" do
    it "keeps existing Discourse values and fills empty ones when the policy is keep" do
      user.user_profile.update!(bio_raw: "Mathematician")

      result =
        write(
          [mapping("bio", policy: "keep"), mapping("website", policy: "keep")],
          { "bio" => "Countess", "website" => "https://example.com" },
        )

      expect(result.changed).to eq(true)
      expect(user.user_profile.reload).to have_attributes(
        bio_raw: "Mathematician",
        website: "https://example.com",
      )
    end

    it "ignores empty CRM values and values Discourse already has" do
      user.user_profile.update!(bio_raw: "Mathematician")

      result = write([mapping("bio"), mapping("name")], { "bio" => "Mathematician", "name" => "" })

      expect(result).to have_attributes(changed: false, rejected: [])
      expect(user.reload.name).to eq("Ada Lovelace")
    end

    it "converts values for typed user fields and custom fields" do
      result =
        write(
          [
            mapping("user_field_#{text_field.id}", source: "phone"),
            mapping("user_field_#{date_field.id}", source: "renewal"),
            mapping("user_field_#{confirm_field.id}", source: "customer"),
            mapping("user_field_#{dropdown_field.id}", source: "tier"),
            mapping("user_field_#{multiselect_field.id}", source: "products"),
            mapping("custom_field:crm_region", source: "region"),
            mapping("custom_field:crm_revenue", source: "revenue"),
            mapping("website"),
          ],
          {
            # Salesforce sends numbers as JSON floats.
            "revenue" => 1.0e7,
            "website" => "acme.io:8443",
            "phone" => "+44 20 7946 0000",
            "renewal" => "2027-01-31T10:00:00.000Z",
            "customer" => "TRUE",
            "tier" => "Gold",
            "products" => "Forum;Chat",
            "region" => "EU",
          },
        )

      expect(result).to have_attributes(changed: true, rejected: [])
      user.reload
      expect(user.user_fields).to include(
        text_field.id.to_s => "+44 20 7946 0000",
        date_field.id.to_s => "2027-01-31",
        confirm_field.id.to_s => true,
        dropdown_field.id.to_s => "Gold",
        multiselect_field.id.to_s => %w[Forum Chat],
      )
      expect(user.custom_fields["crm_region"]).to eq("EU")
      expect(user.custom_fields["crm_revenue"]).to eq("10000000")
      expect(user.user_profile.website).to eq("http://acme.io:8443")
    end

    it "keeps custom fields stored after the user's fields were read" do
      user.custom_fields
      UserCustomField.create!(user: user, name: "other_plugin", value: "kept")

      write([mapping("custom_field:crm_region", source: "region")], { "region" => "EU" })

      expect(UserCustomField.where(user: user).pluck(:name, :value)).to contain_exactly(
        %w[other_plugin kept],
        %w[crm_region EU],
      )
    end

    context "with typed custom fields" do
      before do
        User.register_custom_field_type("crm_score", :integer)
        User.register_custom_field_type("crm_tags", [:string])
        UserCustomField.create!(user: user, name: "crm_score", value: "1")
        UserCustomField.create!(user: user, name: "crm_tags", value: "a")
      end

      after do
        %w[crm_score crm_tags].each { |name| User.send(:custom_field_meta_data).delete(name) }
      end

      it "offers fields by type and stores numbers, rejecting values the field cannot hold" do
        expect(described_class.all).to include(
          a_hash_including(id: "custom_field:crm_score", type: "number"),
        )
        expect(described_class.all.pluck(:id)).not_to include("custom_field:crm_tags")

        mappings = [mapping("custom_field:crm_score", source: "score")]

        expect(write(mappings, { "score" => "42" }).rejected).to be_empty
        expect(user.reload.custom_fields["crm_score"]).to eq(42)
        expect(write(mappings, { "score" => "pending" }).rejected).to eq(["custom_field:crm_score"])
        expect(user.reload.custom_fields["crm_score"]).to eq(42)
        write(mappings, { "score" => "010" })
        expect(user.reload.custom_fields["crm_score"]).to eq(10)
      end
    end

    it "applies watched-word rules to public text fields" do
      text_field.update!(show_on_profile: true)
      Fabricate(:watched_word, word: "blocked")
      Fabricate(:watched_word, word: "censored", action: WatchedWord.actions[:censor])
      mappings = [mapping("user_field_#{text_field.id}", source: "phone"), mapping("bio")]

      result = write(mappings, { "phone" => "a blocked word", "bio" => "Countess" })
      expect(result.rejected).to eq(["user_field_#{text_field.id}"])
      expect(user.user_profile.reload.bio_raw).to eq("Countess")

      write(mappings, { "phone" => "a censored word" })
      expect(user.reload.user_fields[text_field.id.to_s]).not_to include("censored")
    end

    it "skips user fields deleted after the pull was saved" do
      field_id = text_field.id
      text_field.destroy!

      result = write([mapping("user_field_#{field_id}", source: "phone")], { "phone" => "555" })

      expect(result).to have_attributes(changed: false, rejected: [])
      expect(UserCustomField.where(user: user, name: "user_field_#{field_id}")).to be_empty
    end

    it "rejects values Discourse cannot store and still writes the others" do
      short = HasCustomFields::FieldDescriptor.new(:string, 5)
      result =
        stub_const(HasCustomFields, :DEFAULT_FIELD_DESCRIPTOR, short) do
          write(
            [
              mapping("user_field_#{dropdown_field.id}", source: "tier"),
              mapping("user_field_#{date_field.id}", source: "renewal"),
              mapping("name", source: "fullname"),
              mapping("bio"),
              mapping("website"),
              mapping("custom_field:crm_region", source: "region"),
            ],
            {
              "tier" => "Platinum",
              "renewal" => "soon",
              "fullname" => "x" * 300,
              "bio" => "x" * 3001,
              "website" => "https://ada.example.com",
              "region" => "Europe and Africa",
            },
          )
        end

      expect(result.rejected).to contain_exactly(
        "user_field_#{dropdown_field.id}",
        "user_field_#{date_field.id}",
        "name",
        "bio",
        "custom_field:crm_region",
      )
      expect(result.changed).to eq(true)
      user.reload
      expect(user.name).to eq("Ada Lovelace")
      expect(user.user_profile).to have_attributes(bio_raw: nil, website: "https://ada.example.com")
      expect(user.custom_fields["crm_region"]).to be_nil
    end

    it "writes the name of an account that fails newer checks on other attributes" do
      user.update_column(:username, "not a valid username!")

      result = write([mapping("name", source: "fullname")], { "fullname" => "Augusta King" })

      expect(result.rejected).to be_empty
      expect(user.reload.name).to eq("Augusta King")
    end
  end

  describe ".validate!" do
    it "accepts compatible mappings and rejects unknown destinations, incompatible types, bad policies and duplicates" do
      expect {
        described_class.validate!(
          [mapping("name", source: "fullname"), mapping("bio", source: "employees")],
          { "fullname" => "text", "employees" => "number" },
        )
      }.not_to raise_error

      [
        [[mapping("trust", source: "a")], { "a" => "number" }],
        [[mapping("user_field_#{date_field.id}", source: "a")], { "a" => "text" }],
        [[mapping("bio", source: "a", policy: "sometimes")], { "a" => "text" }],
        [
          [mapping("bio", source: "a"), mapping("bio", source: "b")],
          { "a" => "text", "b" => "text" },
        ],
      ].each do |mappings, source_types|
        expect { described_class.validate!(mappings, source_types) }.to raise_error(
          Discourse::InvalidParameters,
        )
      end
    end

    it "rejects fields the login provider overwrites and leaves them out of the list" do
      SiteSetting.auth_overrides_name = true

      expect(described_class.all.pluck(:id)).not_to include("name")

      expect {
        described_class.validate!([mapping("name", source: "a")], { "a" => "text" })
      }.to raise_error(DiscourseCrm::InvalidMapping, /\AName is replaced from the login provider/)
    end
  end
end
