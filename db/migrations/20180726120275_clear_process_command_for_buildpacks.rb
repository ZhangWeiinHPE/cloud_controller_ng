Sequel.migration do
  up do
    self[:processes].update({command: nil})
  end

  down do

  end
end
