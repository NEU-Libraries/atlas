# frozen_string_literal: true

require 'prism'

module ACLCoverage
  # Reads the controllers' source with Prism and answers which methods an
  # action reaches, following calls into the controller's own helpers, its
  # concerns and ApplicationController. A gate called from a helper therefore
  # counts, which a text search could not tell from a comment.
  class Scanner
    # A method's definition and the file that holds it.
    Definition = Struct.new(:node, :path)

    def initialize(root)
      @root  = Pathname(root)
      @files = {}
    end

    # The method names an action calls, directly or through any helper it
    # reaches; nil when the controller does not define the action.
    def calls(controller, action)
      table = method_table(controller_path(controller))
      return nil unless table.key?(action.to_sym)

      reach(table, action.to_sym)
    end

    # True when the controller inherits ApplicationController, so
    # check_authorization guards it at run time.
    def guarded?(controller)
      path = controller_path(controller)
      while path
        return true if path.basename.to_s == 'application_controller.rb'

        path = superclass_path(path)
      end
      false
    end

    def location(controller, action)
      definition = method_table(controller_path(controller))[action.to_sym]
      definition && "#{definition.path.relative_path_from(@root)}:#{definition.node.location.start_line}"
    end

    private

      def reach(table, start)
        seen = Set[start]
        queue = [start]
        until queue.empty?
          calls_in(table.fetch(queue.shift).node).each do |name|
            next unless seen.add?(name) && table.key?(name)

            queue << name
          end
        end
        seen
      end

      def calls_in(node)
        found = []
        stack = [node]
        until stack.empty?
          current = stack.pop
          found << current.name if current.is_a?(Prism::CallNode)
          stack.concat(current.compact_child_nodes)
        end
        found
      end

      # Own definitions override a concern's, which override the superclass's,
      # as Ruby's method lookup does.
      def method_table(path)
        parsed = parse(path)
        table = {}
        table.merge!(method_table(superclass_path(path))) if superclass_path(path)
        parsed[:includes].each { |concern| table.merge!(parse(concern)[:defs]) }
        table.merge!(parsed[:defs])
      end

      def superclass_path(path)
        name = parse(path)[:superclass]
        return nil if name.nil? || name.include?('ActionController')

        @root.join('app/controllers', "#{name.underscore}.rb")
      end

      def controller_path(controller) = @root.join('app/controllers', "#{controller}_controller.rb")

      def parse(path)
        @files[path] ||= begin
          tree = Prism.parse_file(path.to_s).value
          { defs: definitions(tree, path), includes: includes(tree), superclass: superclass(tree) }
        end
      end

      def definitions(tree, path)
        nodes_of(tree, Prism::DefNode).to_h { |node| [node.name, Definition.new(node, path)] }
      end

      # A concern outside app/controllers/concerns, such as a gem's, holds no
      # gate of Atlas's, so it is skipped.
      def includes(tree)
        included = nodes_of(tree, Prism::CallNode).select { |call| call.name == :include && call.receiver.nil? }
        included.flat_map { |call| Array(call.arguments&.arguments) }
                .map { |arg| @root.join('app/controllers/concerns', "#{arg.slice.underscore}.rb") }
                .select(&:exist?)
      end

      def superclass(tree)
        nodes_of(tree, Prism::ClassNode).first&.superclass&.slice
      end

      def nodes_of(tree, type)
        found = []
        stack = [tree]
        until stack.empty?
          current = stack.pop
          found << current if current.is_a?(type)
          stack.concat(current.compact_child_nodes)
        end
        found
      end
  end
end
