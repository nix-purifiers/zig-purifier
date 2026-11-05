extern "provider" fn base() c_int;
export fn answer() c_int { return base() + 1; }
