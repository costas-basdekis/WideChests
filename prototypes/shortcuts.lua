data:extend(
{
	{
		type = 'shortcut',
		name = MergingChests.merge_shortcut_name,
		order = 'b[blueprints]-c[merge-chests]',
		action = 'lua',
		icon =
		{
			filename = '__WideChests__/graphics/icons/merge-shortcut.png',
			priority = 'extra-high-no-scale',
			size = 32,
			scale = 1,
			flags = { 'icon' }
		}
	},
	{
		type = 'shortcut',
		name = MergingChests.merge_full_shortcut_name,
		order = 'b[blueprints]-c[merge-chests]',
		action = 'lua',
		icon =
		{
			filename = '__WideChests__/graphics/icons/merge-full-shortcut.png',
			priority = 'extra-high-no-scale',
			size = 32,
			scale = 1,
			flags = { 'icon' }
		}
	},
})
