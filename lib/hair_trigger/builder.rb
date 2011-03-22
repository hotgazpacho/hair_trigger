module HairTrigger
  class Builder
    attr_accessor :options
    attr_reader :triggers # nil unless this is a trigger group
    attr_reader :prepared_actions, :prepared_where # after delayed interpolation

    def initialize(name = nil, options = {})
      @adapter = options[:adapter] || ActiveRecord::Base.connection rescue nil
      @options = {}
      @chained_calls = []
      set_name(name) if name
      {:timing => :after, :for_each => :row}.update(options).each do |key, value|
        if respond_to?("set_#{key}")
          send("set_#{key}", *Array[value])
        else
          @options[key] = value
        end
      end
    end

    def initialize_copy(other)
      @trigger_group = other
      @triggers = nil
      @chained_calls = []
      @options = @options.dup
      @options.delete(:name) # this will be inferred (or set further down the line)
      @options.each do |key, value|
        @options[key] = value.dup rescue value
      end
    end

    def drop_triggers
      all_names.map{ |name| self.class.new(name, {:table => options[:table], :drop => true}) }
    end

    def name(name)
      raise_or_warn "trigger name cannot exceed 63 for postgres", :postgresql if name.to_s.size > 63
      options[:name] = name.to_s
    end

    def on(table)
      raise "table has already been specified" if options[:table]
      options[:table] = table.to_s
    end

    def for_each(for_each)
      raise_or_warn "sqlite doesn't support FOR EACH STATEMENT triggers", :sqlite if for_each == :statement
      raise "invalid for_each" unless [:row, :statement].include?(for_each)
      options[:for_each] = for_each.to_s.upcase
    end

    def before(*events)
      set_timing(:before)
      set_events(*events)
    end

    def after(*events)
      set_timing(:after)
      set_events(*events)
    end

    def where(where)
      options[:where] = where
    end

    # noop, just a way you can pass a block within a trigger group
    def all
    end

    def security(user)
      return if user == :invoker # default behavior
      raise_or_warn "sqlite doesn't support trigger security clauses", :sqlite
      raise_or_warn "postgresql doesn't support arbitrary users for security clauses", :postgresql unless user == :definer
      options[:security] = user
    end

    def timing(timing)
      raise "invalid timing" unless [:before, :after].include?(timing)
      options[:timing] = timing.to_s.upcase
    end

    def events(*events)
      events << :insert if events.delete(:create)
      events << :delete if events.delete(:destroy)
      raise "invalid events" unless events & [:insert, :update, :delete] == events
      raise_or_warn "sqlite and mysql triggers may not be shared by multiple actions", :mysql, :sqlite if events.size > 1
      options[:events] = events.map{ |e| e.to_s.upcase }
    end

    def prepared_name
      @prepared_name ||= options[:name] ||= infer_name
    end

    def all_names
      [prepared_name] + (@triggers ? @triggers.map(&:prepared_name) : [])
    end

    def self.chainable_methods(*methods)
      methods.each do |method|
        class_eval <<-METHOD
          alias #{method}_orig #{method}
          def #{method}(*args)
            @chained_calls << :#{method}
            if @triggers || @trigger_group
              raise_or_warn "mysql doesn't support #{method} within a trigger group", :mysql unless [:name, :where, :all].include?(:#{method})
            end
            set_#{method}(*args, &(block_given? ? Proc.new : nil))
          end
          def set_#{method}(*args)
            if @triggers # i.e. each time we say t.something within a trigger group block
              @chained_calls.pop # the subtrigger will get this, we don't need it
              @chained_calls = @chained_calls.uniq
              @triggers << trigger = clone
              trigger.#{method}(*args, &Proc.new)
            else
              #{method}_orig(*args)
              maybe_execute(&Proc.new) if block_given?
              self
            end
          end
        METHOD
      end
    end
    chainable_methods :name, :on, :for_each, :before, :after, :where, :security, :timing, :events, :all

    def create_grouped_trigger?
      adapter_name == :mysql
    end

    def prepare!
      @triggers.each(&:prepare!) if @triggers
      @prepared_where = options[:where] = interpolate(options[:where]) if options[:where]
      @prepared_actions = interpolate(@actions).rstrip if @actions
    end

    def generate
      return @triggers.map(&:generate).flatten if @triggers && !create_grouped_trigger?
      prepare!
      raise "need to specify the table" unless options[:table]
      if options[:drop]
        generate_drop_trigger
      else
        raise "no actions specified" if @triggers && create_grouped_trigger? ? @triggers.any?{ |t| t.prepared_actions.nil? } : prepared_actions.nil?
        raise "need to specify the event(s) (:insert, :update, :delete)" if !options[:events] || options[:events].empty?
        raise "need to specify the timing (:before/:after)" unless options[:timing]

        ret = [generate_drop_trigger]
        ret << case adapter_name
          when :sqlite
            generate_trigger_sqlite
          when :mysql
            generate_trigger_mysql
          when :postgresql
            generate_trigger_postgresql
          else
            raise "don't know how to build #{adapter_name} triggers yet"
        end
        ret
      end
    end

    def to_ruby(indent = '')
      prepare!
      if options[:drop]
        "#{indent}drop_trigger(#{prepared_name.inspect}, #{options[:table].inspect}, :generated => true)"
      else
        if @trigger_group
          str = "t." + chained_calls_to_ruby + " do\n"
          str << actions_to_ruby("#{indent}  ") + "\n"
          str << "#{indent}end"
        else
          str = "#{indent}create_trigger(#{prepared_name.inspect}, :generated => true).\n" +
          "#{indent}    " + chained_calls_to_ruby(".\n#{indent}    ")
          if @triggers
            str << " do |t|\n"
            str << "#{indent}  " + @triggers.map{ |t| t.to_ruby("#{indent}  ") }.join("\n\n#{indent}  ") + "\n"
          else
            str << " do\n"
            str << actions_to_ruby("#{indent}  ") + "\n"
          end
          str << "#{indent}end"
        end
      end
    end

    def <=>(other)
      ret = prepared_name <=> other.prepared_name
      ret == 0 ? hash <=> other.hash : ret
    end

    def eql?(other)
      return false unless other.is_a?(HairTrigger::Builder)
      hash == other.hash
    end

    def hash
      prepare!
      [self.options.hash, self.prepared_actions.hash, self.prepared_where.hash, self.triggers.hash].hash
    end

    private

    def chained_calls_to_ruby(join_str = '.')
      @chained_calls.map { |c|
        case c
          when :before, :after, :events
            "#{c}(#{options[:events].map{|c|c.downcase.to_sym.inspect}.join(', ')})"
          when :on
            "on(#{options[:table].inspect})"
          when :where
            "where(#{prepared_where.inspect})"
          else
            "#{c}(#{options[c].inspect})"
        end
      }.join(join_str)
    end

    def actions_to_ruby(indent = '')
      if prepared_actions =~ /\n/
        "#{indent}<<-SQL_ACTIONS\n#{prepared_actions}\n#{indent}SQL_ACTIONS"
      else
        indent + prepared_actions.inspect
      end
    end

    def maybe_execute(&block)
      if block.arity > 0 # we're creating a trigger group, so set up some stuff and pass the buck
        raise_or_warn "trigger group must specify timing and event(s)", :mysql unless options[:timing] && options[:events]
        raise_or_warn "nested trigger groups are not supported for mysql", :mysql if create_grouped_trigger? && @trigger_group
        @triggers = []
        block.call(self)
        raise "trigger group did not define any triggers" if @triggers.empty?
      else
        @actions = block.call
      end
      # only the top-most block actually executes
      Array(generate).each{ |action| @adapter.execute(action)} if options[:execute] && !@trigger_group
      self
    end

    def adapter_name
      @adapter_name ||= @adapter.adapter_name.downcase.to_sym
    end

    def infer_name
      [options[:table],
       options[:timing],
       options[:events],
       options[:for_each],
       prepared_where ? 'when_' + prepared_where : nil
      ].flatten.compact.
      join("_").downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_')[0, 60] + "_tr"
    end

    def generate_drop_trigger
      case adapter_name
        when :sqlite, :mysql
          "DROP TRIGGER IF EXISTS #{prepared_name};\n"
        when :postgresql
          "DROP TRIGGER IF EXISTS #{prepared_name} ON #{options[:table]};\nDROP FUNCTION IF EXISTS #{prepared_name}();\n"
        else
          raise "don't know how to drop #{adapter_name} triggers yet"
      end
    end

    def generate_trigger_sqlite
      <<-SQL
CREATE TRIGGER #{prepared_name} #{options[:timing]} #{options[:events]} ON #{options[:table]}
FOR EACH #{options[:for_each]}#{prepared_where ? " WHEN " + prepared_where : ''}
BEGIN
#{normalize(prepared_actions, 1).rstrip}
END;
      SQL
    end

    def generate_trigger_postgresql
      <<-SQL
CREATE FUNCTION #{prepared_name}()
RETURNS TRIGGER AS $$
BEGIN
#{normalize(prepared_actions, 1).rstrip}
END;
$$ LANGUAGE plpgsql#{options[:security] ? " SECURITY #{options[:security].to_s.upcase}" : ""};
CREATE TRIGGER #{prepared_name} #{options[:timing]} #{options[:events].join(" OR ")} ON #{options[:table]}
FOR EACH #{options[:for_each]}#{prepared_where ? " WHEN (" + prepared_where + ')': ''} EXECUTE PROCEDURE #{prepared_name}();
      SQL
    end

    def generate_trigger_mysql
      security = options[:security]
      if security == :definer
        config = @adapter.instance_variable_get(:@config)
        security = "'#{config[:username]}'@'#{config[:host]}'"
      end
      sql = <<-SQL
CREATE #{security ? "DEFINER = #{security} " : ""}TRIGGER #{prepared_name} #{options[:timing]} #{options[:events].first} ON #{options[:table]}
FOR EACH #{options[:for_each]}
BEGIN
      SQL
      (@triggers ? @triggers : [self]).each do |trigger|
        if trigger.prepared_where
          sql << normalize("IF #{trigger.prepared_where} THEN", 1)
          sql << normalize(trigger.prepared_actions, 2)
          sql << normalize("END IF;", 1)
        else
          sql << normalize(trigger.prepared_actions, 1)
        end
      end
      sql << "END\n";
    end

    def interpolate(str)
      eval("%@#{str.gsub('@', '\@')}@")
    end

    def normalize(text, level = 0)
      indent = level * self.class.tab_spacing
      text.gsub!(/\t/, ' ' * self.class.tab_spacing)
      existing = text.split(/\n/).map{ |line| line.sub(/[^ ].*/, '').size }.min
      if existing > indent
        text.gsub!(/^ {#{existing - indent}}/, '')
      elsif indent > existing
        text.gsub!(/^/, ' ' * (indent - existing))
      end
      text.rstrip + "\n"
    end

    def raise_or_warn(message, *adapters)
      if adapters.include?(adapter_name)
        raise message
      else
        $stderr.puts "WARNING: " + message if self.class.show_warnings
      end
    end

    class << self
      attr_writer :tab_spacing
      attr_writer :show_warnings
      def tab_spacing
        @tab_spacing ||= 4
      end
      def show_warnings
        @show_warnings = true if @show_warnings.nil?
        @show_warnings
      end
    end
  end
end