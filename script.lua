local UIS = game:GetService("UserInputService")

local active = true

-- ton code de test ici

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == Enum.KeyCode.F8 then
		active = false
		print("TEST STOPPÉ")
		
		-- remettre ici les valeurs d'origine si on en a modifié
		script:Destroy()
	end
end)
