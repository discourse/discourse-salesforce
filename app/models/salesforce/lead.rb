# frozen_string_literal: true

module ::Salesforce
  class Lead < Object

    def initialize(opts: {})
      opts.merge!(include_user_payload: true)
      super("lead", opts)
    end

    def create!
      super do |payload|
        payload.merge!({
          LeadSource: ORIGIN,
          Company: DEFAULT_COMPANY_NAME,
          Website: opts[:user].user_profile&.website
        })
      end
    end
  end
end
