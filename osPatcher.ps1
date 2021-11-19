## requirements :
## installazione di  PSWindowsUpdate
## possibilita' di fare connessioni su porta 587 (outgoing)
## possibilita' di scaricare dai repository windows update (http/https)
## un file di configurazione  osPatcher.conf in the format key = value 

$confFile='c:\EngScripts\osPatcher\osPatcher.ps1.conf'
$confExists=(Test-Path -Path $confFile)

if ( -Not (Test-Path -Path $confFile) )
{
   Write-Output("Errore: impossibile trovare il file di configurazione $confFile")
   Exit 2
}

$ExternalVariables = Get-Content -raw -Path $confFile | ConvertFrom-StringData

if ($ExternalVariables.containsKey('MailFrom'))
{
   $MailFrom = $ExternalVariables.MailFrom
   try 
   {
      $null = [mailaddress]$MailFrom
   }
    catch 
   {
      Write-Output("Errore: $MailFrom non e' un indirizzo email valido ")
      exit 5
   }
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per MailFrom")
   Exit 2

}

if ($ExternalVariables.containsKey('MailTo'))
{
   $MailTo = $ExternalVariables.MailTo
   try 
   {
      $null = [mailaddress]$MailTo
   }
    catch 
   {
      Write-Output("Errore: $MailTo non e' un indirizzo email valido ")
      exit 5
   }
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per MailTo")
   Exit 2

}

if ($ExternalVariables.containsKey('userName'))
{
   $userName = $ExternalVariables.userName
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per userName")
   Exit 2

}

if ($ExternalVariables.containsKey('password'))
{
   $password = $ExternalVariables.password
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per password")
   Exit 2

}

if ($ExternalVariables.containsKey('smtpServer'))
{
   $smtpServer = $ExternalVariables.smtpServer
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per smtpServer")
   Exit 2

}

if ($ExternalVariables.containsKey('smtpPort'))
{
   $smtpPort = $ExternalVariables.smtpPort
   try
   {
      $intSmtpPort = [int]$smtpPort
      if ( -not ( ($intSmtpPort -gt 0 ) -and ($intSmtpPort -lt 65535) ))
      {
         Write-Output("Errore: $smtpPort non e' un valore valido di porta TCP")
         exit 6
      }
   }
   catch 
   {
      Write-Output("Errore: $smtpPort non e' un valore intero ")
      exit 5
   }
}
else
{
   Write-Output("Errore: il file di configurazione $confFile non contiene un valore per smtpServer")
   Exit 2

}

$secPasswd = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($userName, $secPasswd)



## provo la connessione smtp
$smtpTest=(tnc -computername $SmtpServer -port $SmtpPort -InformationLevel Quiet)

if ($smtpTest.TcpTestSucceeded -ne 'True')
{
   Write-Output("Errore: impossibile contattare il server smtp $SmtpServer su porta $SmtpPort")
   Exit 3
}

$myhostname=hostname

# verifico se ci sono updates
#$numUpdates=(Get-WindowsUpdate).count
$foundUpdates=(Get-WindowsUpdate)

if ( $foundUpdates.count -gt 0 )
   {
      # Message stuff
      $MessageSubject = "inizio patching per $myhostname"
      $body = $foundUpdates | Out-String
      $body += "`n`n ci sono $numUpdates aggiornamenti da installare"
      Write-Output("$body")
      Send-MailMessage -SmtpServer $smtpServer `
                                   -Credential $cred -port $smtpPort `
                                   -From $MailFrom -To $MailTo `
                                   -Subject $MessageSubject -body $body

      # verifico se un reboot e' necessario
      $needReboot=(Get-WURebootStatus).RebootRequired
      Write-Output("Reboot necessario: $needReboot")

      # scarico e installo gli updates
      $patchResult=(Install-WindowsUpdate -AcceptAll)
      $body=$patchResult | Out-String
      if ($patchResult.Result.contains('Failed') )
      {
         $MessageSubject = "installazione fallita per alcune patch su $myhostname"
      }
      else
      {
         $MessageSubject = "patching per $myhostname completato"
      } 

      if ( $needReboot.RebootRequired -eq 'True' )
        {
            $body += "`n `n eseguo reboot per terminare il patching"
            Send-MailMessage -SmtpServer $smtpServer `
                                         -Credential $cred -port $smtpPort `
                                         -From $MailFrom -To $MailTo `
                                         -Subject $MessageSubject -body $body
            shutdown /r /t 15 /c "os Patching"
        }
      else
        {
           $body = "reboot non necessario"
           Send-MailMessage -SmtpServer $smtpServer `
                                        -Credential $cred -port $smtpPort `
                                        -From $MailFrom -To $MailTo `
                                        -Subject $MessageSubject -body $body
        }
   }
else
   {
      Write-Output("nessun aggiornamento da installare")
   }
