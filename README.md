# Hierarchy
![image](https://i.imgur.com/HGsRt4X.png)

## What is it?
`hierarchy.nvim` replicates the "Call Hierarchy" functionality from VS C*de, showing (recursively) the functions that a given function calls.

## Functionality
With your LSP enabled, hover over a function, use the `:FunctionReferences` command, and observe the call hierarchy of that function. Press `<Enter>` over an item in the list to expand its list of children, and type `gd` over an item to jump to its definition.

## Installation
Using [lazy](https://github.com/folke/lazy.nvim):
```lua
return {
    'lafarr/hierarchy.nvim'
}
```

## Default Options
```lua
local opts = {
    -- Determines how many levels deep the call hierarchy shows
    depth = 3
}
```

## Usage
In your `init.lua`:
```lua
vim.api.nvim_create_autocmd({ 'LspAttach' }, {
    group = 'Hierarchy',
    desc = 'Set up the :FunctionReferences user command',
    callback = function()
        local opts = {
            -- Your opts here
        }
        require('hierarchy').setup(opts)
    end
})
```

Now, navigate your cursor over a function and use the `:FunctionReferences` command
