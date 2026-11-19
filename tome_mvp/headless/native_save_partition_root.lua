-- A root for native Level partitions. The payload remains the original slot
-- and Level objects; class.save determines their actual serialized fields.
require 'engine.class'
module(...,package.seeall,class.make)
function _M:init(slot) self.slot=slot end
