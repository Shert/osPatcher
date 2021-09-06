#!/bin/bash

# Version 1.0.3

# patcher for linux deb/rpm based systems
#
# 2021-07-12 Mario Caruso
#

function printHelp ()
{
   echo "Questo script aggiorna le patches di OS sul server in cui viene eseguito"
   echo "opzioni : -t=|--updatetool= (apt|yum)"
   echo "opzioni : -s=|--statusFile= path assoluto del file dove e' salvata la data di ultima applicazione patches"
   echo "opzioni : -us|--updateStatusFile Forza l'aggiornamento del file di Status"
   echo "opzioni : -c=|--configFile= path del file di configurazione"
   echo "opzioni : -rs|--randomSleep esegue uno sleep per evitare di partire subito"
   echo "opzioni : -rsm=|--randomSleepMax= il valore massimo per cui fare lo sleep"
   echo "opzioni : -f|--forceRun"
   echo "opzioni : -d|--dryrun"
   echo "opzioni : -nm|--noMail (non invia le e-mail di notifica)"
   echo "opzioni : -nr|--noReboot (non esegue il reboot del server)"
   echo "opzioni : -w=|--whenToRun= (15|15+5|1Tue|3Tue|2Wed|now)"
   echo "opzioni : -r=|--recipients= indirizzi email (separati da virgola) a cui inviare notifiche"
   echo "opzioni : -sts=|--stopServices= servizi da fermare (tramite systemd) prima di eseguire il patching (nomi delle unit separati da virgola)"
   echo "opzioni : -stc=|--stopCommands= comandi da eseguire prima di eseguire il patching (separati da virgola)"
   echo "opzioni : -lf=|--logFacility="
   echo "opzioni : -lt=|--logTag="
   echo "opzioni : -ls|--logStandardOutput"
   echo "opzioni : -h=|--help= mostra questo help"
}

function setDefaults ()
{
   PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
   export PATH
   api_key='xxx'
   api_secret='xxx'
   updatetool='yum'
   dryRun="False"
   shouldIRun='False'
   shouldIUpdateStatusFile='False'
   shouldIReboot='False'
   disableReboot='False'
   shouldISendEmail='True'
   whenToRun='never'
   recipients='costacmg-ux@eng.it'
   jsonRecipients=''
   statusFile="/tmp/osPatcher.stats"
   configFile=""
   lastPatchDate="0"
   shouldIrandomSleep='False'
   randomSleepMax='120'
   stopServices="False"
   stopCommands="False"
   logFacility=local2.info
   logTag="osPatcher"
   logStandardOutput="False"
}

function randomSleep ()
{
   mySleep=$(expr $RANDOM % $randomSleepMax)
   sleep ${mySleep}
}

function logMessages()
{
   logMessage=${1}
      if [[ "${logStandardOutput}" == "True"  ]];then
         echo "${logMessage}"
      fi
      logger -t ${logTag} -p ${logFacility} ${logMessage}
}

function checkIfIShouldRun ()
{
   #  min2wed  8 ; max2wed 13
   #  min3tue  14 ;  max3tue  20

   dayOfWeek=$(LC_TIME=C date +%a)
   dayOfMonth=$(date +%d)
   case ${whenToRun} in
      15)
         if [[ "${dayOfMonth}" == "${whenToRun}" ]];then
            shouldIRun='True'
         fi
      ;;
      
      15+5)
         if [[ ${dayOfMonth} -ge 23 && "${dayOfWeek}" !=  "Sat" && "${dayOfWeek}" !=  "Sun" ]];then
            nowDate=$(date +%s)            
            daysSinceLastPatch=$((${nowDate} - ${lastPatchDate}))
            if [[ ${daysSinceLastPatch} -gt 777600 ]];then
               shouldIRun='True'
            fi
         fi
      ;;
      
      3Tue)
         if [[ "${dayOfWeek}" ==  "Tue" && "${dayOfMonth}" -ge 14 && "${dayOfMonth}" -le 20 ]];then
             shouldIRun='True'
         fi
      ;;
      
       1Tue)
         if [[ "${dayOfWeek}" ==  "Tue" && "${dayOfMonth}" -ge 1 && "${dayOfMonth}" -le 7 ]];then
             shouldIRun='True'
         fi
      ;;     
      2Wed)
         if [[ "${dayOfWeek}" ==  "Wed" && "${dayOfMonth}" -ge 8 && "${dayOfMonth}" -le 13 ]];then
             shouldIRun='True'
         fi
      ;;
      
      now)
         shouldIRun='True'
      ;;      

      never)
         logMessage="Warning: no whenToRun specified, please specify a value"
         logMessages "${logMessage}"
      ;;
   esac
   
}

function sendNotificationEmail ()
{
   #echo ${jsonRecipients}
   curl -s \
      -X POST \
      --user "$api_key:$api_secret" \
      https://api.mailjet.com/v3/send \
      -H 'Content-Type: application/json' \
      -d "{
         'FromEmail':'costacmg-ux@eng.it',
         'FromName':'Engineering',
         'Subject':'${subject}',
         'Text-part':'${body}',
         'Recipients':[${jsonRecipients}]
         }"
}

function validateNeeds ()
{
   needed=(grep awk mktemp date curl logger ${updatetool})
   for ((i=0;i<${#needed[@]};i++))
      do
         bpath=$(which ${needed[i]})
         if [ -z "${bpath}" ];then
            logMessage="Error: unable to find a valid ${needed[i]}"
            logMessages "${logMessage}"
            exit 2
         else
            if ! [ -x "${bpath}" ];then
               logMessage="Error: ${needed[i]} is not executable"
               logMessages "${logMessage}"
               exit 3
            fi
         fi
      done
   
   ### validazione valore di myExpectedStart
   if [[ ! "${whenToRun}" =~ ^(15|15+5|1Tue|3Tue|2Wed|never|now) ]] ;then
      logMessage="Error: value ${whenToRun} for whenToRun is not valid/accepted"
      logMessages "${logMessage}"
      exit 5
   fi
   
   ### validazione valore di randomSleepMax
   expr ${randomSleepMax} \/ 1 > /dev/null 2>/dev/null
   if [[ $? -ne 0 ]];then
      logMessage="Error: value ${randomSleepMax} for randomSleepMax is not valid (should be an integer)"
      logMessages "${logMessage}"
      exit 6
   fi
}

function generateJsonRecipients
{
   ### mail validation 
   #^(([-a-zA-Z0-9\!#\$%\&\'*+/=?^_\`{\|}~])+\.)*[-a-zA-Z0-9\!#\$%\&\'*+/=?^_\`{\|}~]+@\w((-|\w)*\w)*\.(\w((-|\w)*\w)*\.)*\w{2,4}$
   IFS=','
   jsonRecipients=""
   for recipient in ${recipients}
   do
      #echo ${recipient}
      if [[ -z ${jsonRecipients} ]];then
         jsonRecipients+="{\"Email\":\"${recipient}\"}"
      else
         jsonRecipients+=",{\"Email\":\"${recipient}\"}"
      fi
   done
   unset IFS
}

function updateStatusFile ()
{
   if [[ -n ${statusFile} ]];then
      nowDate=$(date +%s)
      echo "lastPatchDate=${nowDate}" >  ${statusFile}
   fi
}

function main()
{
   setDefaults
     
   while [[ "$#" > 0 ]]
   do
      key="${1}"
      case ${key} in         
         -h|--help)
            printHelp
            exit 0
         ;;
         
         -t=*|--updatetool=*)
            updatetool=${key#*=}
         ;;

         -s=*|--statusFile=*)
            statusFile=${key#*=}
         ;;
         
         -us|--updateStatusFile)
            shouldIUpdateStatusFile="True"
         ;;

         -c=*|--configFile=*)
            configFile=${key#*=}
         ;;

         -f|--forceRun)
            shouldIRun="True"
         ;;
         
         -d|--dryrun)
            dryRun="True"
         ;;
         
         -nm|--noMail)
            shouldISendEmail="False"
         ;;
         
          -nr|--noReboot)
            disableReboot="True"
         ;;
         
         -w=*|--whenToRun=*)
            whenToRun=${key#*=}
         ;;
      
         -r=*|--recipients=*)
            recipients=${key#*=}
         ;;

          -rs|--randomSleep)
            shouldIrandomSleep="True"
         ;;

         -rsm=*|--randomSleepMax=*)
            randomSleepMax=${key#*=}
         ;;
         
         -sts=*|--stopServices=*)
            stopServices=${key#*=}
         ;;
         
         -stc=*|--stopCommands=*)
            stopCommands=${key#*=}
         ;;
         
         -lf=*|--logFacility=*)
            logFacility=${key#*=}
         ;;

         -lt=*|--logTag=*)
            logTag=${key#*=}
         ;;
         
          -ls|--logStandardOutput)
            logStandardOutput="True"
         ;;
         *)
            logMessage="parametro ${key} non gestito"
            logMessages ${logMessage}
            exit 6
         ;;
      esac
      shift
   done
   
   if [[ -n ${configFile} ]];then
      if [[ -s ${configFile} ]];then
         source ${configFile}
      fi
   fi
   
   if [[ -n ${statusFile} ]];then
      if [[ -s ${statusFile} ]];then
         source ${statusFile}
      fi
   fi
   
   validateNeeds
   
   checkIfIShouldRun
   
   if [[ "${shouldIRun}" == "True"  ]];then
   
      if [[ "${shouldIrandomSleep}" == "True" ]];then
         randomSleep
      fi
      
      #echo "devo girare"
      myName=$(hostname -f)
      
      if [[ "${shouldISendEmail}" == "True" ]];then
         generateJsonRecipients
      fi
      
      if [[ "${dryRun}" == "False" ]];then
         startDate=$(date)
         subject="inizio patching per ${myName}"
         if [[ "${updatetool}" == "yum" ]];then
            command="${updatetool} -y update"
            body="${startDate} - avvio ${updatetool} update"
         elif [[ "${updatetool}" == "apt" ]];then
            command="${updatetool} update && ${updatetool} -y upgrade"
            body="${startDate} - avvio ${updatetool} upgrade"
         fi
         if [[ "${shouldISendEmail}" == "True" ]];then
            sendNotificationEmail
         fi
         
         if [[ "${stopServices}" != "False" ]];then
            IFS=','
            for currentService in ${stopServices}
            do
               unset IFS
               systemctl  stop ${currentService}
               IFS=','
            done
            unset IFS
         fi

         if [[ "${stopCommands}" != "False" ]];then
            IFS=','
            for stopCommand in ${stopCommands}
            do
               unset IFS
               ${stopCommand}
               IFS=','
            done
            unset IFS
         fi
         
         if [[ "${updatetool}" == "yum" ]];then
            ${updatetool} -y update
            retCode=$?
         elif [[ "${updatetool}" == "apt" ]];then
            ${updatetool} update && ${updatetool} -y upgrade
            retCode=$?
         fi
         endDate=$(date)
         if [[ ${retCode} -eq 0 ]];then
            if [[ ${disableReboot} == 'False' ]];then
               subject="patching per ${myName} completato"
               body="${endDate} - installazione patches completate, esecuzione reboot"
               shouldIReboot="True"
               shouldIUpdateStatusFile="True"
            else
               subject="patching per ${myName} completato"
               body="${endDate} - installazione patches completate, non verra' eseguito reboot come da configurazione"
            fi
         else
            subject="patching per ${myName} NON completato"
            body="${endDate} - installazione patches fallita (${retCode})"
         fi
      else
         endDate=$(date)
         subject="dryrun per ${myName} completato"
         body="${endDate} - eseguito dryrun"
      fi
      if [[ "${shouldISendEmail}" == "True" ]];then
         sendNotificationEmail
      fi      
      if [[ "${shouldIUpdateStatusFile}" == "True" ]];then
         updateStatusFile
      fi
      if [[ "${shouldIReboot}" == "True" ]];then
         reboot
      fi
   fi
}

main $*
