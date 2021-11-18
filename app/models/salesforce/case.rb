# frozen_string_literal: true

module ::Salesforce
  class Case < Object

    def initialize(opts: {})
      super("case", opts)
    end

    def create!
      super do |payload|
        payload.merge!({
          Status: "New",
          Origin: ORIGIN,
          ContactId: user.email
        })
      end
    end
  end
end
