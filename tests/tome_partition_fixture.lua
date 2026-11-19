require 'engine.class'
module(...,package.seeall,class.make)
function _M:init(name)self.name=name end
function _M.identity(x)return x+1 end
function _M.twice(x)return x*2 end
