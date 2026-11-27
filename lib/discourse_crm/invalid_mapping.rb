# frozen_string_literal: true

module DiscourseCrm
  # A mapping that is well formed but conflicts with site settings or other configurations.
  # The message is translated and shown to the admin as is.
  class InvalidMapping < StandardError
    attr_reader :mapping, :mapping_index

    def initialize(message, mapping: nil)
      super(message)
      @mapping = mapping
    end

    # Lets the form show the message next to the mapping the admin submitted.
    def locate(mappings)
      @mapping_index = mappings.index { |item| item.equal?(mapping) } if mapping
    end
  end
end
