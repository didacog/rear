#
# Propose new network interface if original interface MAC is not found on the current system.
#
# Migrate network device configuration found in /etc/udev/rules.d/*persistent*{net|names}*.rules
# to match different hardware from the source system.
# We assume that udev or static module loading was used to load the
# appropriate drivers and do not do anything about driver loading.
#
# If network interface name is not managed by udev ( > rhel7 and > ubuntu 16.04 ),
# update 60-network-devices.sh and 62-routing.sh system-setup script (inet renamed, migration)
# adjusts the udev rule and triggers udev.
#

# Get the rule files (though it should be only one):
RULE_FILES=( /etc/udev/rules.d/*persistent*{names,net}.rules )
ORIG_MACS_FILE=/etc/mac-addresses
MAC_MAPPING_FILE=/etc/rear/mappings/mac
MANUAL_MAC_MAPPING=
network_setup_scripts=( "/etc/scripts/system-setup.d/60-network-devices.sh" "/etc/scripts/system-setup.d/62-routing.sh" )

# First check the existence of the original network devices:
# The MIGRATE_MACS array collects the MAC addresses that we need to migrate:
MIGRATE_MACS=()
# The ORIGINAL_MACS array collects the original MAC addresses:
ORIGINAL_MACS=()
# The ORIGINAL_DEVICES collects the original device names:
ORIGINAL_DEVICES=()
# The ORIG_MACS_FILE contains lines of the form: network_interface mac_address
# TODO: What should happen if there is no ORIG_MACS_FILE or when it is empty?
while read orig_dev orig_mac junk ; do
    ORIGINAL_DEVICES=( "${ORIGINAL_DEVICES[@]}" "$orig_dev")
    ORIGINAL_MACS=( "${ORIGINAL_MACS[@]}" "$orig_mac" )
    # Continue with the next original MAC address if it is found on the current system:
    ip link show | grep -q "$orig_mac" && continue
    MIGRATE_DEVNAMES=( "${MIGRATE_DEVNAMES[@]}" "$orig_dev" )
    MIGRATE_MACS=( "${MIGRATE_MACS[@]}" "$orig_mac" )
done < $ORIG_MACS_FILE

# Skip this process if all MACs and network interfacs (devices) are accounted for:
test ${#MIGRATE_MACS[@]} -eq 0 && test ${#MIGRATE_DEVNAMES[@]} -eq 0 && return 0

# Find the MAC addresses that are now available.
# This is an array with values of the form "$dev $mac $driver"
# which is similar to /etc/mac-addresses but with the driver information added:
NEW_DEVICES=()
for dev_dir in /sys/class/net/* ; do
    # basename $dev_dir
    dev="${dev_dir##*/}"
    case $dev in
        # Skip all kind of internal devices:
        (lo|pan*|sit*|tun*|tap*|vboxnet*|vmnet*) continue ;;
    esac
    # Skip unless we have a MAC address:
    test -s $dev_dir/address || continue
    # Read first word from address file:
    read mac junk <$dev_dir/address
    # Skip devices without MAC address:
    test "$mac" = "00:00:00:00:00:00" && continue
    # Get the drivers.
    # E.g. 'udevadm info -a -p /sys/class/net/eth0'
    # prints a list of DRIVER[S]=="module" lines like
    #    DRIVER==""
    #    DRIVERS=="8139cp"
    #    DRIVERS==""
    # where only non-empty values get stored in the drivers array:
    drivers=( $( my_udevinfo -a -p /sys/class/net/$dev | sed -ne '/DRIVER.*=".\+"/s/.*"\(.*\)".*/\1/p' ) )
    # The drivers array contains a list of drivers, but I care only about the first one:
    NEW_DEVICES=( "${NEW_DEVICES[@]}" "$dev $mac $drivers" )
done

# Check the existence of a valid mapping file.
# The file is valid, if at least one "old" mac is mapped to an existing new one:
if read_and_strip_file $MAC_MAPPING_FILE ; then
    while read orig_dev orig_mac junk ; do
        read_and_strip_file $MAC_MAPPING_FILE | grep -q "$orig_mac" && MANUAL_MAC_MAPPING=true
    done < $ORIG_MACS_FILE
fi

# Let the user choose replacement network interfaces (unless manual mapping is specified).
# When there is only one original MAC and only one network interface on the current system
# automatically map the original MAC to the new MAC of the current network interface:
if ! test $MANUAL_MAC_MAPPING ; then
    # Abandon this process if no manual mapping should be done and the ORIGINAL_MACS array is empty
    # because when the ORIGINAL_MACS array is empty it does not make sense to let the user choose something:
    if test ${#ORIGINAL_MACS[@]} -lt 1 ; then
        echo "Skipping network interface migration because no MAC address of the original system is known"
        return 0
    fi
    # Abandon this process if no manual mapping should be done and the NEW_DEVICES array is empty
    # because when the NEW_DEVICES array is empty it is impossible to let the user choose something:
    if test ${#NEW_DEVICES[@]} -lt 1 ; then
        echo "Cannot migrate network interface setup because there is no usable MAC address on this system"
        return 0
    fi
    # Ensure the directory of the MAC_MAPPING_FILE is there:
    mkdir -p $( dirname $MAC_MAPPING_FILE )
    # If there is only one original MAC and only one NEW_DEVICES array element
    # automatically map the original MAC to the new one:
    if test ${#ORIGINAL_MACS[@]} -eq 1 -a ${#NEW_DEVICES[@]} -eq 1 ; then
        index=0
        old_dev=${ORIGINAL_DEVICES[$index]}
        old_mac=${ORIGINAL_MACS[$index]}
        choice="${NEW_DEVICES[$index]}"
        # Split choice="dev mac driver" into words:
        dev_mac_driver=( $choice )
        new_dev=${dev_mac_driver[0]}
        new_mac=${dev_mac_driver[1]}
        # Output the old_mac->new_mac mapping for later use below:
        echo "$old_mac $new_mac $old_dev" >>$MAC_MAPPING_FILE
        # Get new device name from current MAC address:
        new_dev=$( get_device_by_hwaddr "$new_mac" )
        # Tell the user about the automated mapping (and how he could avoid it):
        echo "The only original network interface $old_dev $old_mac is not available"
        echo "and no mapping is specified in $MAC_MAPPING_FILE"
        echo "Mapping it to the only available $new_dev $new_mac"
    else
        # When there is more than one original MAC or more than one NEW_DEVICES array elements
        # loop over all the original MACs and ask the user to specify a replacement
        # even though maybe some MACs stayed we want to offer the user the option to
        # reassign all MAC addresses. That is why we loop over all the original MACs and
        # not only over the MACs that require reassignment:
        for (( index=0 ; index < ${#ORIGINAL_MACS[@]} ; index++ )) ; do
            old_dev=${ORIGINAL_DEVICES[$index]}
            old_mac=${ORIGINAL_MACS[$index]}
            echo "The original network interface $old_dev $old_mac is not available"
            PS3="Choose replacement for $old_dev $old_mac "
            skip_choice="Skip replacing $old_dev $old_mac"
            select choice in "${NEW_DEVICES[@]}" "$skip_choice" ; do
                # Invalid input causes choice to be set to null:
                test "$choice" || continue
                # User selected to skip replacing the network interface:
                if test "$skip_choice" = "$choice" ; then
                    echo "Skipping $old_dev $old_mac (you may have to manually fix your network setup)"
                    # Continue with next MAC address in the outer 'for' loop:
                    continue 2
                fi
                # User selected one of the NEW_DEVICES array elements:
                break
            done
            # Split choice="dev mac driver" into words:
            dev_mac_driver=( $choice )
            new_dev=${dev_mac_driver[0]}
            new_mac=${dev_mac_driver[1]}
            # Output the old_mac->new_mac mapping for later use below:
            echo "$old_mac $new_mac $old_dev" >>$MAC_MAPPING_FILE
            # Prepare the 'select' choices for the next MAC address:
            # When one of the NEW_DEVICES array elements was selected
            # replace the selected NEW_DEVICES array element with the empty string
            # (i.e. do not remove that element from the NEW_DEVICES array)
            # so that for the next MAC address in the 'for' loop an already
            # selected NEW_DEVICE is no longer actually shown in the select list but
            # there is still an empty choice (with number) shown in the select list
            # so that the choice numbers for the remaining NEW_DEVICES
            # stay the same for all MAC addresses during the 'for' loop:
            NEW_DEVICES=( "${NEW_DEVICES[@]/$choice/}" )
        done
    fi
fi

# Initialize reload_udev variable to false because
# below we reload udev only if we actually have MAC mappings:
reload_udev=false

# Actually do the MAC mappings (if any).
# There could be no non-empty MAC mapping file when above
# the user had skipped replacing any network interface:
if test -s $MAC_MAPPING_FILE ; then
    # MAC_MAPPING_FILE contains "$old_mac $new_mac $old_dev" lines:
    while read old_mac new_mac old_dev junk ; do
        # Get new device name from current MAC address:
        new_dev=$( get_device_by_hwaddr "$new_mac" )
        # Migrate udev persistent-net rules files (if any):
        if test $RULE_FILES ; then
            if grep -q "$old_mac" "${RULE_FILES[@]}" ; then
                # Remove the "wrong" line with the new mac address and
                # replace the old mac address with the new mac address:
                sed -i -e "/$new_mac/d" -e "s#$old_mac#$new_mac#gI" "${RULE_FILES[@]}"
                reload_udev=true
            else
                if grep -q "$old_dev" "${RULE_FILES[@]}" ; then
                    # Remove the "wrong" line with the new mac address and
                    # rename the new device name with the old one:
                    test "$new_dev" && sed -i -e "/$old_dev/d" -e "s#$new_dev#$old_dev#g" "${RULE_FILES[@]}"
                    reload_udev=true
                else
                    # Device is not managed by udev rules.
                    # We have to update the network_setup_scripts with the new interface name:
                    test "$new_dev" && sed -i -e "s#$old_dev#$new_dev#g" "${network_setup_scripts[@]}"
                fi
            fi
        else
            # Device is not managed by udev rules.
            # We have to update the network_setup_scripts with the new interface name:
            test "$new_dev" && sed -i -e "s#$old_dev#$new_dev#g" "${network_setup_scripts[@]}"
        fi
    done < <( read_and_strip_file "$MAC_MAPPING_FILE" )
fi

# Reload udev if we have MAC mappings:
if is_true $reload_udev ; then
    echo -n "Reloading udev ... "
    my_udevtrigger
    sleep 1
    my_udevsettle
    if test "$( ps --no-headers -C systemd )" ; then
        # This might be not mandatory.
        # It will release orphaned (old) device names in systemd
        # Maybe it can be done by some less invazive command, but I didn't found it yet:
        systemctl daemon-reload
    fi
    echo "done."
fi

# A later script in finalize/* will also go over the MAC mappings file and
# apply them to the files in the recovered system.

