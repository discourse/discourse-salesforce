# frozen_string_literal: true

module DiscourseCrm
  class SegmentsController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME

    include GuidedSyncEndpoint

    before_action :ensure_segments_enabled

    def index
      configurations = SyncConfiguration.active.user_pulls.order(:id).to_a
      render json: {
               segments:
                 serialize_data(
                   Segment.includes(:group, :configuration).order(:id),
                   SegmentSerializer,
                   member_counts: SegmentMember.group(:segment_id).count,
                 ),
               configurations:
                 configurations.map do |configuration|
                   {
                     id: configuration.id,
                     name: configuration.name,
                     provider: configuration.provider,
                   }
                 end,
               properties: available_properties(configurations),
               groups: available_groups,
             }
    end

    def create
      Segment::Create.call(service_params) do |result|
        on_success { |segment:| render json: serialize_segment(segment), status: :created }
        on_failed_contract do |contract|
          render_json_error(contract.errors.full_messages, status: :bad_request)
        end
        on_failed_policy(:can_manage) { raise Discourse::InvalidAccess }
        on_model_not_found(:configuration) { render_no_pull }
        on_model_not_found(:pulled_properties) { render_no_pull }
        on_model_errors(:segment) { |segment| render_json_error(segment) }
        on_failed_policy(:properties_are_pulled) do |_, segment:, pulled_properties:|
          render_property_not_pulled(segment, pulled_properties)
        end
        on_failed_step(:save_segment) { |_, segment:| render_json_error(segment) }
      end
    end

    def update
      Segment::Update.call(segment_params) do |result|
        on_success { |segment:| render json: serialize_segment(segment) }
        on_failed_contract do |contract|
          render_json_error(contract.errors.full_messages, status: :bad_request)
        end
        on_failed_policy(:can_manage) { raise Discourse::InvalidAccess }
        on_model_not_found(:segment) { raise Discourse::NotFound }
        on_model_errors(:segment) { |segment| render_json_error(segment) }
        on_model_not_found(:pulled_properties) { render_no_pull }
        on_failed_policy(:properties_are_pulled) do |_, segment:, pulled_properties:|
          render_property_not_pulled(segment, pulled_properties)
        end
        on_failed_step(:save_segment) { |_, segment:| render_json_error(segment) }
      end
    end

    def destroy
      Segment::Destroy.call(segment_params) do |result|
        on_success { head :no_content }
        on_failed_contract do |contract|
          render_json_error(contract.errors.full_messages, status: :bad_request)
        end
        on_failed_policy(:can_manage) { raise Discourse::InvalidAccess }
        on_model_not_found(:segment) { raise Discourse::NotFound }
      end
    end

    def preview
      Segment::Preview.call(service_params) do |result|
        on_success { |preview:| render json: preview }
        on_failed_contract do |contract|
          render_json_error(contract.errors.full_messages, status: :bad_request)
        end
        on_failed_policy(:can_manage) { raise Discourse::InvalidAccess }
        on_model_not_found(:configuration) { render_no_pull }
        on_model_not_found(:pulled_properties) { render_no_pull }
        on_model_errors(:segment) { |segment| render_json_error(segment) }
        on_failed_policy(:properties_are_pulled) do |_, segment:, pulled_properties:|
          render_property_not_pulled(segment, pulled_properties)
        end
      end
    end

    private

    def ensure_segments_enabled
      raise Discourse::NotFound unless SiteSetting.crm_segments_enabled
    end

    def segment_params
      service_params.deep_merge(params: { segment_id: params[:id] })
    end

    def serialize_segment(segment)
      serialize_data(segment, SegmentSerializer, root: false)
    end

    def render_no_pull
      render_json_error(
        I18n.t("salesforce.segments.errors.no_pull_configured"),
        status: :unprocessable_entity,
      )
    end

    def render_property_not_pulled(segment, pulled_properties)
      render_json_error(
        I18n.t(
          "salesforce.segments.errors.property_not_pulled",
          property: segment.missing_properties(pulled_properties).first,
        ),
        status: :unprocessable_entity,
      )
    end

    def available_properties(configurations)
      configurations.flat_map do |configuration|
        properties = configuration.pulled_properties
        labels = property_labels(configuration.provider_definition, properties)
        properties.map do |property|
          {
            id: "#{property[:object]}.#{property[:name]}",
            configuration_id: configuration.id,
            object: property[:object],
            name: property[:name],
            label: labels.dig(property[:object], property[:name]) || property[:name],
          }
        end
      end
    end

    def property_labels(definition, properties)
      flow = definition.flow("inbound", "users")
      return {} if flow.nil?
      properties
        .map { |property| property[:object] }
        .uniq
        .to_h { |object| [object, flow.property_labels(object)] }
    rescue ::Hubspot::InvalidCredentials,
           ::Hubspot::InvalidApiResponse,
           ::Salesforce::InvalidCredentials,
           ::Salesforce::InvalidApiResponse,
           Faraday::Error
      {}
    end

    def available_groups
      Group
        .where(automatic: false)
        .order(:name)
        .pluck(:id, :name, :user_count)
        .map { |id, name, user_count| { id:, name:, user_count: } }
    end
  end
end
