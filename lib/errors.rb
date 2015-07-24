[:BambooAgentInfoError, :BambooAgentPageSignatureError, :BambooMasterServerError, :BamgooAgentInfoError, :ExtraConfigurationParameterError, :FilePathError,
 :ForkingProvisionerDefinitionError, :MissingConfigurationParameterError, :NilConfigurationValueError, :NilVMError, :OpenNebulaTemplateError,
 :PathNilError, :PoolInformationError, :StageNumberNilError, :UnexpectedSecureValueError, :UnknownActionError,
 :UnknownConfigurationTypeError, :UnknownProvisioningStageError, :VMIPError, :UnknownConfigurationKeyValueError,
 :FileLocationError, :StageFileExistsError, :SeveralTemplatesMatchesError, :TemplateNotFoundError, :EmptyActionArray].each do |error|
  Object.const_set(error.to_s, Class.new(StandardError))
end
