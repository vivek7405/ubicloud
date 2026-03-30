# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "vm") do |r|
    r.get api? do
      vm_list_api_response(vm_list_dataset)
    end

    r.on VM_NAME_OR_UBID do |vm_name, vm_id|
      if vm_name
        r.post api? do
          check_visible_location
          vm_post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => vm_id}
      end

      filter[:location_id] = @location.id
      vm = @vm = @project.vms_dataset.first(filter)
      check_found_object(vm)

      r.get true do
        authorize("Vm:view", vm)

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          r.redirect vm, "/overview"
        end
      end

      r.delete true do
        authorize("Vm:delete", vm)

        DB.transaction do
          vm.incr_destroy
          audit_log(vm, "destroy")
        end

        if web?
          flash["notice"] = "Virtual machine scheduled for deletion."
          r.redirect @project, "/vm"
        else
          204
        end
      end

      r.post "restart" do
        authorize("Vm:edit", vm)

        DB.transaction do
          vm.incr_restart
          audit_log(vm, "restart")
        end

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          flash["notice"] = "'#{vm.name}' will be restarted in a few seconds"
          r.redirect vm, "/settings"
        end
      end

      r.post "stop" do
        authorize("Vm:edit", vm)

        DB.transaction do
          vm.incr_stop
          audit_log(vm, "stop")
        end

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          flash["notice"] = "'#{vm.name}' will be stopped"
          r.redirect vm, "/settings"
        end
      end

      r.post "checkpoint" do
        authorize("Vm:edit", vm)
        body = JSON.parse(r.body.read) rescue {}
        pilot_id = body["pilot_id"]
        checkpoint_id = body["checkpoint_id"]

        source = "/mnt/juicefs/vms/#{vm.inhost_name}/0/disk.raw"
        dest_dir = "/mnt/juicefs/checkpoints/#{pilot_id}/#{checkpoint_id}"
        dest = "#{dest_dir}/disk.raw"

        vm.vm_host.sshable.cmd("sudo mkdir -p #{dest_dir.shellescape} && sudo juicefs clone #{source.shellescape} #{dest.shellescape}")

        if api?
          {"checkpoint_id" => checkpoint_id, "status" => "created"}
        else
          204
        end
      end

      r.post "restore" do
        authorize("Vm:edit", vm)
        body = JSON.parse(r.body.read) rescue {}
        pilot_id = body["pilot_id"]
        checkpoint_id = body["checkpoint_id"]

        source = "/mnt/juicefs/checkpoints/#{pilot_id}/#{checkpoint_id}/disk.raw"
        dest = "/mnt/juicefs/vms/#{vm.inhost_name}/0/disk.raw"

        host = vm.vm_host
        host.sshable.cmd("sudo systemctl stop #{vm.inhost_name}")
        host.sshable.cmd("sudo rm -f #{dest.shellescape} && sudo juicefs clone #{source.shellescape} #{dest.shellescape}")
        host.sshable.cmd("sudo truncate -s $(stat -c%s #{source.shellescape}) #{dest.shellescape}")
        host.sshable.cmd("sudo systemctl start #{vm.inhost_name}")

        if api?
          {"checkpoint_id" => checkpoint_id, "status" => "restored"}
        else
          204
        end
      end

      r.rename vm, perm: "Vm:edit", serializer: Serializers::Vm, template_prefix: "vm"

      r.show_object(vm, actions: %w[overview networking settings], perm: "Vm:view", template: "vm/show")
    end
  end
end
