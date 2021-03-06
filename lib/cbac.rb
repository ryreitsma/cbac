require "active_record"

# TODO: Check the permission table for double entries, ie: both an entry in the
# generic_role_id field and an entry in the context_role field. Solution: solve
# via model. Update model & add test
require "cbac/setup"
require "cbac/config"
require "cbac/context_role"
require "cbac/generic_role"
require "cbac/known_permission"
require "cbac/membership"
require "cbac/permission"
require "cbac/privilege"
require "cbac/privilege_new_api"
require "cbac/privilege_set"
require "cbac/privilege_set_record"
require "cbac/cbac_pristine/pristine"
require "cbac/cbac_pristine/pristine_file"
require "cbac/cbac_pristine/pristine_permission"
require "cbac/cbac_pristine/pristine_role"

# The following code contains configuration options. You can turn them on for
# gem development. For actual usage, it is advisable to set the configuration
# options in the environment files.
Cbac::Config.verbose = true

# Module containing the bootstrap code
module Cbac
  def cbac_boot!
    if Cbac::Setup.check
      puts "CBAC properly installed"

      # check performs a check to see if the user is allowed to access the given
      # resource. Example: authorization_check("BlogController", "index", :get)
      def authorization_check(controller, action, request, context = {})
        # Determine the controller to look for
        controller_method = [controller, action].join("/")
        # Get the privilegesets
        privilege_sets = Privilege.select(controller_method, request)
        # Check the privilege sets
        check_privilege_sets(privilege_sets, context)
      end

      # Check the given privilege_set symbol
      # TODO following code is not yet tested
      def check_privilege_set(privilege_set, context = {})
        check_privilege_sets([PrivilegeSet.sets[privilege_set.to_sym]], context)
      end

      # Check the given privilege_sets
      def check_privilege_sets(privilege_sets, context = {})
        # Check the generic roles
        return true if privilege_sets.any? { |set|
          Cbac::GenericRole.joins(:generic_role_members, :permissions).exists?(
            'cbac_memberships.user_id'  => current_user,
            'cbac_permissions.privilege_set_id' => set.id
          )
        }

        # Check the context roles Get the permissions
        privilege_sets.collect{|privilege_set|Cbac::Permission.find(:all, :conditions => ["privilege_set_id = ? AND generic_role_id = 0", privilege_set.id.to_s])}.flatten.each do |permission|
          puts "Checking for context_role:#{permission.context_role} on privilege_set:#{permission.privilege_set.name}" if Cbac::Config.verbose
          eval_string = ContextRole.roles[permission.context_role.to_sym]
          begin
            return true if eval_string.call(context)
          rescue Exception => e
            puts "Error in context role: #{permission.context_role} on privilege_set: #{permission.privilege_set.name}. Context: #{context}"
            if %w{development test}.include? Rails.env
              raise e # In development mode, this should crash as hard as possible, but in further stages, it should not
            end
          end
        end
        # not authorized
        puts "Not authorized for: #{privilege_sets.to_s}" if Cbac::Config.verbose
        false
      end

      # Code that performs authorization
      def authorize
        authorization_check(params[:controller], params[:action], request.request_method.downcase, self) || unauthorized
      end

      # Default unauthorized method Override this method to supply your own code
      # for incorrect authorization
      def unauthorized
        render :text => "You are not authorized to perform this action", :status => 401
      end

      # Default implementation of the current_user method
      def current_user_id
        session[:currentuser].to_i
      end

      # Load controller classes and methods
      def load_controller_methods
        begin
          Dir.glob("app/controllers/**/*.rb").each{|file| require file}
        rescue LoadError
          raise "Could not load controller classes"
        end
        # Make this iterative TODO
        @classes = ApplicationController.subclasses
      end

      # Extracts the class name from the filename
      def extract_class_name(filename)
        File.basename(filename).chomp(".rb").camelize
      end

      # ### Initializer Include privileges file - contains the privilege and
      # privilege definitions
      begin
        require File.join(::Rails.root.to_s, "config", "cbac", "privileges.rb")
      rescue MissingSourceFile
        puts "CBAC warning: Could not load config/cbac/privileges.rb (Did you run ./script/generate cbac?)"
      end
      # Include context roles file - contains the context role definitions
      begin
        require File.join(::Rails.root.to_s, "config", "cbac", "context_roles.rb")
      rescue MissingSourceFile
        puts "CBAC warning: Could not load config/cbac/context_roles.rb (Did you run ./script/generate cbac?)"
      end

      # ### Database autoload code
    else
      # This is the code that is executed if CBAc is not properly installed/
      # configured. It includes a different authorize method, aimes at refusing
      # all authorizations
      def authorize
        render :text => "Authorization error", :status => 401
        false
      end
    end
  end
end
