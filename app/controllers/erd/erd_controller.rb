require 'nokogiri'
require 'rails_erd/diagram/graphviz'
require 'erd/application_controller'

module Erd
  class ErdController < ::Erd::ApplicationController
    def index
      Rails.application.eager_load!
      RailsERD.options[:filename], RailsERD.options[:filetype] = Rails.root.join('tmp/erd'), 'plain'
      RailsERD::Diagram::Graphviz.create
      plain = Rails.root.join('tmp/erd.plain').read
      positions = if (json = Rails.root.join('tmp/erd_positions.json')).exist?
        ActiveSupport::JSON.decode json.read
      else
        {}
      end
      @erd = render_plain plain, positions

      @migrations = Erd::Migrator.status
    end

    def update
      changes = ActiveSupport::JSON.decode(params[:changes])
      executed_migrations, failed_migrations = [], []
      changes.each do |row|
        begin
          action, model, column, from, to = row['action'], row['model'].tableize, row['column'], row['from'], row['to']
          case action
          when 'remove_model'
            generated_migration_file = Erd::Migrator.execute_generate_migration "drop_#{model}"
            gsub_file generated_migration_file, /def up.*  end/m, "def change\n    drop_table :#{model}\n  end"
            Erd::Migrator.run_migrations :up => generated_migration_file
            executed_migrations << generated_migration_file
          when 'rename_model'
            from, to = from.tableize, to.tableize
            generated_migration_file = Erd::Migrator.execute_generate_migration "rename_#{from}_to_#{to}"
            gsub_file generated_migration_file, /def up.*  end/m, "def change\n    rename_table :#{from}, :#{to}\n  end"
            Erd::Migrator.run_migrations :up => generated_migration_file
            executed_migrations << generated_migration_file
          when 'add_column'
            name_and_type = column.scan(/(.*)\((.*?)\)/).first
            name, type = name_and_type[0], name_and_type[1]
            generated_migration_file = Erd::Migrator.execute_generate_migration "add_#{name}_to_#{model}", ["#{name}:#{type}"]
            Erd::Migrator.run_migrations :up => generated_migration_file
            executed_migrations << generated_migration_file
          when 'rename_column'
            generated_migration_file = Erd::Migrator.execute_generate_migration "rename_#{model}_#{from}_to_#{to}"
            gsub_file generated_migration_file, /def up.*  end/m, "def change\n    rename_column :#{model}, :#{from}, :#{to}\n  end"
            Erd::Migrator.run_migrations :up => generated_migration_file
            executed_migrations << generated_migration_file
          when 'alter_column'
            generated_migration_file = Erd::Migrator.execute_generate_migration "change_#{model}_#{column}_type_to_#{to}"
            gsub_file generated_migration_file, /def up.*  end/m, "def change\n    change_column :#{model}, :#{column}, :#{to}\n  end"
            Erd::Migrator.run_migrations :up => generated_migration_file
            executed_migrations << generated_migration_file
          when 'move'
            json_file = Rails.root.join('tmp', 'erd_positions.json')
            positions = json_file.exist? ? ActiveSupport::JSON.decode(json_file.read) : {}
            positions[model] = to
            json_file.open('w') {|f| f.write positions.to_json}
          else
            raise "unexpected action: #{action}"
          end
        rescue ::Erd::MigrationError => e
          failed_migrations << e.message
        end
      end

      redirect_to erd.root_path, :flash => {:executed_migrations => {:up => executed_migrations}, :failed_migrations => failed_migrations}
    end

    def migrate
      Erd::Migrator.run_migrations :up => params[:up], :down => params[:down]
      redirect_to erd.root_path, :flash => {:executed_migrations => params.slice(:up, :down)}
    end

    private
    def render_plain(plain, positions)
      _scale, svg_width, svg_height = plain.scan(/\Agraph ([0-9\.]+) ([0-9\.]+) ([0-9\.]+)$/).first
      ratio = [BigDecimal('4800') / BigDecimal(svg_width), BigDecimal('3200') / BigDecimal(svg_height), 180].min
      # node name x y width height label style shape color fillcolor
      models = plain.scan(/^node ([^ ]+) ([0-9\.]+) ([0-9\.]+) ([0-9\.]+) ([0-9\.]+) <\{?(<((?!^\}?>).)*)^\}?> [^ ]+ [^ ]+ [^ ]+ [^ ]+\n/m).map {|node_name, x, y, width, height, label|
        label_doc = Nokogiri::HTML::DocumentFragment.parse(label)
        model_name = node_name.sub(/^m_/, '')
        next if model_name == 'ActiveRecord::SchemaMigration'
        columns = []
        if (cols_table = label_doc.search('table')[1])
          columns = cols_table.search('tr > td').map {|col| col_name, col_type = col.text.split(' '); {:name => col_name, :type => col_type}}
        end
        custom_x, custom_y = positions[model_name.tableize].try(:split, ',')
        {:model => model_name, :x => (custom_x || BigDecimal(x) * ratio), :y => (custom_y || BigDecimal(y) * ratio), :width => BigDecimal(width) * ratio, :height => height, :columns => columns}
      }.compact
      # edge tail head n x1 y1 .. xn yn [label xl yl] style color
      edges = plain.scan(/^edge ([^ ]+)+ ([^ ]+)/).map {|from, to| {:from => from.sub(/^m_/, ''), :to => to.sub(/^m_/, '')}}
      render_to_string 'erd/erd/erd', :layout => nil, :locals => {:width => BigDecimal(svg_width) * ratio, :height => BigDecimal(svg_height) * ratio, :models => models, :edges => edges}
    end

    def gsub_file(path, flag, *args, &block)
      path = File.expand_path path, Rails.root

      content = File.read path
      content.gsub! flag, *args, &block
      File.open(path, 'w') {|file| file.write content}
    end
  end
end
