class Cbac::PrivilegeSetRecord < ActiveRecord::Base
  self.table_name = "cbac_privilege_set"

  attr_accessible :name

  def set_comment(comment)
    self.comment = comment if has_attribute?("comment")    
  end
end
