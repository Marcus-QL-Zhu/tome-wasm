-- Native Savefile object root. It deliberately carries native class objects;
-- it is not an alternate actor or item encoder.
require 'engine.class'
module(..., package.seeall, class.make)
function _M:init(game_object, world_object, application)
 self.game=game_object
 self.world=world_object
 self.application=application
end
