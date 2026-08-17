# frozen_string_literal: true

require Rails.root.join(
          "plugins/discourse-salesforce/db/migrate/20260817203816_add_unique_index_to_salesforce_cases_topic_id.rb",
        )

RSpec.describe AddUniqueIndexToSalesforceCasesTopicId do
  fab!(:topic)

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    DB.exec("DROP INDEX index_salesforce_cases_on_topic_id")
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  it "keeps only the most recently synced case per topic and enforces uniqueness" do
    Fabricate(:salesforce_case, topic: topic, last_synced_at: 2.days.ago)
    newest_synced = Fabricate(:salesforce_case, topic: topic, last_synced_at: 1.hour.ago)
    Fabricate(:salesforce_case, topic: topic, last_synced_at: nil)
    unrelated_case = Fabricate(:salesforce_case)

    described_class.new.up

    expect(Salesforce::Case.where(topic_id: topic.id).pluck(:id)).to eq([newest_synced.id])
    expect(Salesforce::Case.exists?(unrelated_case.id)).to eq(true)
    expect { Fabricate(:salesforce_case, topic: topic) }.to raise_error(
      ActiveRecord::RecordNotUnique,
    )
  end
end
