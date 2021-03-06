module VCAP::CloudController
  class RouteMappingCreate
    class InvalidRouteMapping < StandardError
    end
    class DuplicateRouteMapping < InvalidRouteMapping
    end
    class SpaceMismatch < InvalidRouteMapping
    end
    class RoutingApiDisabledError < InvalidRouteMapping
    end

    DUPLICATE_MESSAGE = 'Duplicate Route Mapping - Only one route mapping may exist for an application, route, and port'.freeze

    class << self
      def add(user_audit_info, route, process, manifest_triggered: false)
        validate!(process.app, route)

        route_mapping = RouteMappingModel.new(
          app: process.app,
          route: route,
          process_type: process.type,
          app_port: VCAP::CloudController::ProcessModel::DEFAULT_HTTP_PORT
        )

        route_handler = ProcessRouteHandler.new(process)

        RouteMappingModel.db.transaction do
          route_mapping.save
          route_handler.update_route_information

          Repositories::AppEventRepository.new.record_map_route(
            process.app,
            route,
            user_audit_info,
            route_mapping: route_mapping,
            manifest_triggered: manifest_triggered
          )
        end

        route_mapping
      rescue Sequel::ValidationFailed => e
        if e.errors && e.errors.on([:app_guid, :route_guid, :process_type, :app_port]) && e.errors.on([:app_guid, :route_guid, :process_type, :app_port]).include?(:unique)
          raise DuplicateRouteMapping.new(DUPLICATE_MESSAGE)
        end

        raise InvalidRouteMapping.new(e.message)
      end

      private

      def validate!(app, route)
        validate_routing_api_enabled!(route)
        validate_space!(app, route)
      end

      def validate_space!(app, route)
        return if app.space.guid == route.space.guid

        raise SpaceMismatch.new("The app cannot be mapped to route #{route.uri} because the route is not in this space. Apps must be mapped to routes in the same space.")
      end

      def validate_routing_api_enabled!(route)
        if Config.config.get(:routing_api).nil? && route.domain.shared? && route.domain.router_group_guid
          raise RoutingApiDisabledError.new('Routing API is disabled')
        end
      end
    end
  end
end
