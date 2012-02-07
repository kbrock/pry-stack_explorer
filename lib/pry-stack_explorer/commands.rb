require 'pry'

module PryStackExplorer
  module FrameHelpers
    private

    # @return [PryStackExplorer::FrameManager] The active frame manager for
    #   the current `Pry` instance.
    def frame_manager
      PryStackExplorer.frame_manager(_pry_)
    end

    # @return [Array<PryStackExplorer::FrameManager>] All the frame
    #   managers for the current `Pry` instance.
    def frame_managers
      PryStackExplorer.frame_managers(_pry_)
    end

    # @return [Boolean] Whether there is a context to return to once
    #   the current `frame_manager` is popped.
    def prior_context_exists?
      frame_managers.count > 1 || frame_manager.prior_binding
    end

    # Return a description of the frame (binding).
    # This is only useful for regular old bindings that have not been
    # enhanced by `#of_caller`.
    # @param [Binding] b The binding.
    # @return [String] A description of the frame (binding).
    def frame_description(b)
      b_self = b.eval('self')
      b_method = b.eval('__method__')

      if b_method && b_method != :__binding__ && b_method != :__binding_impl__
        b_method.to_s
      elsif b_self.instance_of?(Module)
        "<module:#{b_self}>"
      elsif b_self.instance_of?(Class)
        "<class:#{b_self}>"
      else
        "<main>"
      end
    end

    # Return a description of the passed binding object. Accepts an
    # optional `verbose` parameter.
    # @param [Binding] b The binding.
    # @param [Boolean] verbose Whether to generate a verbose description.
    # @return [String] The description of the binding.
    def frame_info(b, verbose = false)
      meth = b.eval('__method__')
      b_self = b.eval('self')
      meth_obj = Pry::Method.from_binding(b) if meth

      type = b.frame_type ? "[#{b.frame_type}]".ljust(9) : ""
      desc = b.frame_description ? "#{b.frame_description}" : "#{frame_description(b)}"
      sig = meth_obj ? "<#{signature_with_owner(meth_obj)}>" : ""

      self_clipped = "#{Pry.view_clip(b_self)}"
      path = "@ #{b.eval('__FILE__')}:#{b.eval('__LINE__')}"

      if !verbose
        "#{type} #{desc} #{sig}"
      else
        "#{type} #{desc} #{sig}\n      in #{self_clipped} #{path}"
      end
    end

    # @param [Pry::Method] meth_obj The method object.
    # @return [String] Signature for the method object in Class#method format.
    def signature_with_owner(meth_obj)
      if !meth_obj.undefined?
        args = meth_obj.parameters.inject([]) do |arr, (type, name)|
          name ||= (type == :block ? 'block' : "arg#{arr.size + 1}")
          arr << case type
                 when :req   then name.to_s
                 when :opt   then "#{name}=?"
                 when :rest  then "*#{name}"
                 when :block then "&#{name}"
                 else '?'
                 end
        end
        "#{meth_obj.name_with_owner}(#{args.join(', ')})"
      else
        "#{meth_obj.name_with_owner}(UNKNOWN) (undefined method)"
      end
    end
  end

  Commands = Pry::CommandSet.new do
    create_command "up", "Go up to the caller's context. Accepts optional numeric parameter for how many frames to move up." do
      include FrameHelpers

      banner <<-BANNER
        Usage: up [OPTIONS]
          Go up to the caller's context. Accepts optional numeric parameter for how many frames to move up.
          e.g: up
          e.g: up 3
      BANNER

      def process
        inc = args.first.nil? ? 1 : args.first.to_i

        if !frame_manager
          raise Pry::CommandError, "Nowhere to go!"
        else
          frame_manager.change_frame_to frame_manager.binding_index + inc
        end
      end
    end

    create_command "down", "Go down to the callee's context. Accepts optional numeric parameter for how many frames to move down." do
      include FrameHelpers

      banner <<-BANNER
        Usage: down [OPTIONS]
          Go down to the callee's context. Accepts optional numeric parameter for how many frames to move down.
          e.g: down
          e.g: down 3
      BANNER

      def process
        inc = args.first.nil? ? 1 : args.first.to_i

        if !frame_manager
          raise Pry::CommandError, "Nowhere to go!"
        else
          if frame_manager.binding_index - inc < 0
            raise Pry::CommandError, "At bottom of stack, cannot go further!"
          else
            frame_manager.change_frame_to frame_manager.binding_index - inc
          end
        end
      end
    end

    create_command "show-stack", "Show all frames" do
      include FrameHelpers

      banner <<-BANNER
        Usage: show-stack [OPTIONS]
          Show all accessible stack frames.
          e.g: show-stack -v
      BANNER

      def options(opt)
        opt.on :v, :verbose, "Include extra information."
        opt.on :H, :head, "Display the first N stack frames (defaults to 10).", :optional => true, :as => Integer, :default => 10
        opt.on :T, :tail, "Display the last N stack frames (defaults to 10).", :optional => true, :as => Integer, :default => 10
      end

      def memoized_info(index, b, verbose)
        frame_manager.user[:frame_info] ||= Hash.new { |h, k| h[k] = [] }

        if verbose
          frame_manager.user[:frame_info][:v][index]      ||= frame_info(b, verbose)
        else
          frame_manager.user[:frame_info][:normal][index] ||= frame_info(b, verbose)
        end
      end

      private :memoized_info

      # @return [Array<Fixnum, Array<Binding>>] Return tuple of
      #   base_frame_index and the array of frames.
      def selected_stack_frames
        if opts.present?(:head)
          [0, frame_manager.bindings[0..(opts[:head] - 1)]]
        elsif opts.present?(:tail)
          tail = opts[:tail]
          if tail > frame_manager.bindings.size
            tail = frame_manager.bindings.size
          end

          base_frame_index = frame_manager.bindings.size - tail
          puts base_frame_index
          [base_frame_index, frame_manager.bindings[base_frame_index..-1]]
        else
          [0, frame_manager.bindings]
        end
      end

      private :selected_stack_frames

      def process
        if !frame_manager
          output.puts "No caller stack available!"
        else
          content = ""
          content << "\n#{text.bold("Showing all accessible frames in stack (#{frame_manager.bindings.size} in total):")}\n--\n"

          base_frame_index, frames = selected_stack_frames
          frames.each_with_index do |b, index|
            i = index + base_frame_index
            if i == frame_manager.binding_index
              content << "=> ##{i} #{memoized_info(i, b, opts[:v])}\n"
            else
              content << "   ##{i} #{memoized_info(i, b, opts[:v])}\n"
            end
          end

          stagger_output content
        end

      end
    end

    create_command "frame", "Switch to a particular frame. Accepts numeric parameter for the target frame to switch to (use with show-stack). Negative frame numbers allowed." do
      include FrameHelpers

      banner <<-BANNER
        Usage: frame [OPTIONS]
          Switch to a particular frame. Accepts numeric parameter for the target frame to switch to (use with show-stack). Negative frame numbers allowed.
          When given no parameter show information about the current frame.

          e.g: frame 4   #=> jump to the 4th frame
          e.g: frame -2  #=> jump to the second-to-last frame
          e.g: frame     #=> show information info about current frame
      BANNER

      def process
        if !frame_manager
          raise Pry::CommandError, "nowhere to go!"
        else

          if args[0]
            frame_manager.change_frame_to args[0].to_i
          else
            output.puts "##{frame_manager.binding_index} #{frame_info(target, true)}"
          end
        end
      end
    end
  end
end
