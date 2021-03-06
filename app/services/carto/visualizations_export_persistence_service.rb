require 'uuidtools'
require_dependency 'carto/uuidhelper'
require_dependency 'carto/query_rewriter'

module Carto
  # Export/import is versioned, but importing should generate a model tree that can be persisted by this class
  class VisualizationsExportPersistenceService
    include Carto::UUIDHelper
    include Carto::QueryRewriter

    # `full_restore = true` means keeping the visualization id and permission. Its intended use is to restore an exact
    # copy of a visualization (e.g: user migration). When it's `false` it will skip restoring ids and permissions. This
    # is the default, and how it's used by the Import API to allow to import a visualization into a different user
    def save_import(user, visualization, renamed_tables: {}, full_restore: false)
      old_username = visualization.user.username if visualization.user
      apply_user_limits(user, visualization)
      ActiveRecord::Base.transaction do
        visualization.id = random_uuid unless visualization.id && full_restore
        visualization.user = user

        ensure_unique_name(user, visualization)

        visualization.layers.each { |layer| layer.fix_layer_user_information(old_username, user, renamed_tables) }
        visualization.analyses.each do |analysis|
          analysis.analysis_node.fix_analysis_node_queries(old_username, user, renamed_tables)
        end

        saved_acl = visualization.permission.access_control_list if full_restore
        visualization.permission = Carto::Permission.new(owner: user, owner_username: user.username)

        map = visualization.map
        map.user = user

        visualization.analyses.each do |analysis|
          analysis.user_id = user.id
        end

        sync = visualization.synchronization
        if sync
          sync.id = random_uuid
          sync.user = user
          sync.log.user_id = user.id
        end

        user_table = visualization.map.user_table
        if user_table
          user_table.user = user
          user_table.service.register_table_only = true
          raise 'Cannot import a dataset without physical table' unless user_table.service.real_table_exists?
        end

        unless visualization.save
          raise "Errors saving imported visualization: #{visualization.errors.full_messages}"
        end

        # Save permissions after visualization, in order to be able to regenerate shared_entities
        if saved_acl
          visualization.permission.access_control_list = saved_acl
          visualization.permission.save!
        end

        visualization.layers.map do |layer|
          # Flag needed because `.changed?` won't realize about options hash changes
          changed = false
          if layer.options.has_key?(:id)
            layer.options[:id] = layer.id
            changed = true
          end
          if layer.options.has_key?(:stat_tag)
            layer.options[:stat_tag] = visualization.id
            changed = true
          end
          layer.save if changed
        end

        map.data_layers.each(&:register_table_dependencies)

        new_user_layers = map.base_layers.select(&:custom?).select { |l| !contains_equivalent_base_layer?(user.layers, l) }
        new_user_layers.map(&:dup).map { |l| user.layers << l }
      end

      # Propagate changes (named maps, default permissions and so on)
      visualization_member = CartoDB::Visualization::Member.new(id: visualization.id).fetch
      visualization_member.store

      visualization
    end

    private

    def contains_equivalent_base_layer?(layers, layer)
      layers.any? { |l| equivalent_base_layer?(l, layer) }
    end

    def equivalent_base_layer?(layer_a, layer_b)
      layer_a.kind == 'tiled' && layer_a.kind == layer_b.kind && layer_a.options == layer_b.options
    end

    def ensure_unique_name(user, visualization)
      existing_names = Carto::Visualization.uniq
                                           .where(user_id: user.id)
                                           .where("name ~ ?", "#{Regexp.escape(visualization.name)}( Import)?( \d*)?$")
                                           .where(type: visualization.type)
                                           .pluck(:name)
      if existing_names.include?(visualization.name)
        raise 'Cannot rename a dataset during import' if visualization.canonical?
        import_name = "#{visualization.name} Import"
        i = 1
        while existing_names.include?(import_name)
          import_name = "#{visualization.name} Import #{i += 1}"
        end
        visualization.name = import_name
      end
    end

    def apply_user_limits(user, visualization)
      visualization.privacy = Carto::Visualization::PRIVACY_PUBLIC unless user.private_maps_enabled
      # Since password is not exported we must fallback to private
      if visualization.privacy == Carto::Visualization::PRIVACY_PROTECTED
        visualization.privacy = Carto::Visualization::PRIVACY_PRIVATE
      end

      layers = []
      data_layer_count = 0
      visualization.map.layers.each do |layer|
        if layer.data_layer?
          if data_layer_count < user.max_layers
            layers.push(layer)
            data_layer_count += 1
          end
        else
          layers.push(layer)
        end
      end
      visualization.map.layers = layers
    end
  end
end
