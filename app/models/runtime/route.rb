require 'cloud_controller/dea/client'

module VCAP::CloudController
  class Route < Sequel::Model
    ROUTE_REGEX = /\A#{URI.regexp}\Z/

    class InvalidDomainRelation < VCAP::Errors::InvalidRelation; end
    class InvalidAppRelation < VCAP::Errors::InvalidRelation; end
    class InvalidOrganizationRelation < VCAP::Errors::InvalidRelation; end
    class DockerDisabled < VCAP::Errors::InvalidRelation; end

    many_to_one :domain
    many_to_one :space, after_set: :validate_changed_space

    # This is a v3 relationship
    one_to_many :route_mappings, class: 'VCAP::CloudController::RouteMappingModel', key: :route_guid, primary_key: :guid

    # This is a v2 relationship for the /v2/route_mappings endpoints and associations
    one_to_many :app_route_mappings, class: 'VCAP::CloudController::RouteMapping'

    many_to_many :apps,
                 distinct: true,
                 order: Sequel.asc(:id),
                 before_add:   :validate_app,
                 after_add:    :handle_add_app,
                 after_remove: :handle_remove_app

    one_to_one :route_binding
    one_through_one :service_instance, join_table: :route_bindings

    add_association_dependencies apps: :nullify, route_mappings: :destroy

    export_attributes :host, :path, :domain_guid, :space_guid, :service_instance_guid, :port
    import_attributes :host, :path, :domain_guid, :space_guid, :app_guids, :port

    def fqdn
      host.empty? ? domain.name : "#{host}.#{domain.name}"
    end

    def uri
      "#{fqdn}#{path}"
    end

    def as_summary_json
      {
        guid:   guid,
        host:   host,
        path:   path,
        domain: {
          guid: domain.guid,
          name: domain.name
        }
      }
    end

    alias_method :old_path, :path
    def path
      old_path.nil? ? '' : old_path
    end

    alias_method :old_port, :port
    def port
      old_port.nil? ? 0 : old_port
    end

    def organization
      space.organization if space
    end

    def route_service_url
      route_binding && route_binding.route_service_url
    end

    def validate
      validates_presence :domain
      validates_presence :space

      errors.add(:host, :presence) if host.nil?

      validates_format /^([\w\-]+|\*)$/, :host if host && !host.empty?

      if path.empty?
        # This is only for routes controller translate_validation_exception method
        # in order to distinguish between hostname being taken and path being
        # taken
        validates_unique [:host, :domain_id, :port] do |ds|
          ds.where(path: '')
        end
      else
        validates_unique [:host, :domain_id, :path, :port]
      end

      validate_host_and_domain_in_different_space
      validate_path
      validate_domain
      validate_total_routes
      validate_ports
      validate_total_reserved_route_ports if port > 0
      errors.add(:host, :domain_conflict) if domains_match?
    end

    def validate_ports
      errors.add(:port, :invalid_port) if port < 0 || port > 65535
    end

    def validate_path
      return if path == ''

      if !ROUTE_REGEX.match("pathcheck://#{host}#{path}")
        errors.add(:path, :invalid_path)
      end

      if path == '/'
        errors.add(:path, :single_slash)
      end

      if path[0] != '/'
        errors.add(:path, :missing_beginning_slash)
      end

      if path =~ /\?/
        errors.add(:path, :path_contains_question)
      end
    end

    def domains_match?
      return false if domain.nil? || host.nil? || host.empty?
      !Domain.find(name: fqdn).nil?
    end

    def all_apps_diego?
      apps.all?(&:diego?)
    end

    def validate_app(app)
      return unless space && app && domain

      unless app.space == space
        raise InvalidAppRelation.new(app.guid)
      end

      unless domain.usable_by_organization?(space.organization)
        raise InvalidDomainRelation.new(domain.guid)
      end
    end

    # If you change this function, also change _add_route in app.rb
    def _add_app(app, hash={})
      app_port = app.user_provided_ports.first unless app.user_provided_ports.blank?
      model.db[:apps_routes].insert(hash.merge(app_id: app.id, app_port: app_port, route_id: id, guid: SecureRandom.uuid))
    end

    def validate_changed_space(new_space)
      apps.each { |app| validate_app(app) }
      raise InvalidOrganizationRelation if domain && !domain.usable_by_organization?(new_space.organization)
    end

    def self.user_visibility_filter(user)
      {
         space_id: Space.dataset.join_table(:inner, :spaces_developers, space_id: :id, user_id: user.id).select(:spaces__id).union(
           Space.dataset.join_table(:inner, :spaces_managers, space_id: :id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :spaces_auditors, space_id: :id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :organizations_managers, organization_id: :organization_id, user_id: user.id).select(:spaces__id)
           ).union(
             Space.dataset.join_table(:inner, :organizations_auditors, organization_id: :organization_id, user_id: user.id).select(:spaces__id)
           ).select(:id)
       }
    end

    def in_suspended_org?
      space.in_suspended_org?
    end

    private

    def before_destroy
      destroy_route_bindings
      super
    end

    def destroy_route_bindings
      errors = ServiceBindingDelete.new.delete(self.route_binding_dataset)
      raise errors.first unless errors.empty?
    end

    def around_destroy
      loaded_apps = apps
      super

      loaded_apps.each do |app|
        handle_remove_app(app)

        if app.dea_update_pending?
          Dea::Client.update_uris(app)
        end
      end
    end

    def validate_host_and_domain_in_different_space
      return unless space && domain && domain.shared?

      validates_unique [:domain_id, :host], message: :host_and_domain_taken_different_space do |ds|
        ds.where(port: 0).exclude(space: space)
      end
    end

    def handle_add_app(app)
      app.handle_add_route(self)
    end

    def handle_remove_app(app)
      app.handle_remove_route(self)
    end

    def validate_domain
      errors.add(:domain, :invalid_relation) if !valid_domain
      errors.add(:host, 'is required for shared-domains') if !valid_host_for_shared_domain
    end

    def valid_domain
      return false if domain.nil?

      domain_change = column_change(:domain_id)
      return false if !new? && domain_change && domain_change[0] != domain_change[1]

      return false if space && !domain.usable_by_organization?(space.organization) # domain is not usable by the org

      true
    end

    def valid_host_for_shared_domain
      return false if domain && domain.shared? && (!host.present? && !old_port.present?) # domain is shared and no host is present
      true
    end

    def validate_total_routes
      return unless new? && space

      space_routes_policy = MaxRoutesPolicy.new(space.space_quota_definition, SpaceRoutes.new(space))
      org_routes_policy   = MaxRoutesPolicy.new(space.organization.quota_definition, OrganizationRoutes.new(space.organization))

      if space.space_quota_definition && !space_routes_policy.allow_more_routes?(1)
        errors.add(:space, :total_routes_exceeded)
      end

      if !org_routes_policy.allow_more_routes?(1)
        errors.add(:organization, :total_routes_exceeded)
      end
    end

    def validate_total_reserved_route_ports
      return unless new? && space
      route_port_counter = OrganizationReservedRoutePorts.new(space.organization)
      quota_definition = space.organization.quota_definition
      reserved_route_ports_policy = MaxReservedRoutePortsPolicy.new(quota_definition, route_port_counter)

      if !reserved_route_ports_policy.allow_more_route_ports?
        errors.add(:organization, :total_reserved_route_ports_exceeded)
      end
    end
  end
end