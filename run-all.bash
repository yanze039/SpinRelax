#!/bin/bash

function get_script_location() {
    local SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
        local DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
        local SOURCE="$(readlink "$SOURCE")"
        [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
        # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    local DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    echo $DIR
}

function convert_Diso() {
    # See Garcia et al., J Magn Res, 2000 + Wong and Case, J Phys Chem B, 2008
    awk -v D1=$1 -v T1=$2 -v T2=$3 -v cD2O=$4 \
'function eta(T) {
    T=T-273
    return 1.7753 - 5.65e-2*T + 1.0751e-3*T^2 - 9.222e-6*T^3
}
function D2Omod(ratio){
    return 1.23*ratio+(1.0-ratio)
}
BEGIN {
    print D1 * (1.0*T2/T1) * ( 1.0*eta(T1)/eta(T2) ) * D2Omod(cD2O)
}'
}

function determine_time_factor() {
    # Converts to script internal units of picoseconds.
    case $1 in
        s)  echo 1.0e12 ;;
        ms) echo 1.0e9  ;;
        us) echo 1.0e6  ;;
        ns) echo 1.0e3  ;;
        ps) echo 1.0 ;;
        *) echo "= = ERROR: I cannot understand the time units given! $1" > /dev/stderr ; exit 1 ;;
    esac
}

function =() {
    local in="$(echo "$@" | sed -e 's/\[/(/g' -e 's/\]/)/g')"
    # echo "in=$in"
    awk 'BEGIN {print '"$in"'}' < /dev/null
}

function assert_file() {
    while [[ $# -gt 0 ]] ; do
        [ ! -e $1 ] && { echo >&2 "= = File $1 does not exist. Will abort." ; exit -1 ; }
        shift
    done
}

function gmx_type() {
    if type gmx >& /dev/null ; then echo "5.x" ; elif type mdrun >& /dev/null ; then echo "4.x" ; else echo "none" ; fi
}

#Determine GROMACS version
gtyp=$(gmx_type)
case $gtyp in
    5.x)
    gcheck="gmx check"
    ;;
    4.x)
    gcheck="gmxcheck"
    ;;
    *)
    echo "= = No GROMACS found! = ="
    exit -1
    ;;
esac

pycmd=python
plumed=plumed

# By default, look in the current folder.
bMulti=False
folderfile=
foldlist=.
bMultiRef=False

script_loc=$(get_script_location)
echo "Script location: $script_loc"
T_md=300 ; T_exp=297 ; c_D2O=0.09
sxtc=solute.xtc
xtc_step=''
qfile=colvar-qorient
pfile_template=$script_loc/plumed-quat-template.dat
pfile=plumed-quat.dat
refpdb=reference.pdb
vecStorage=Histogram
expfn=""
tpr=topol.tpr
# Decide on memory time to use for reorientation time.
tau_ns=10 ; tau_ps=$(= $tau_ns*1000) ; t100=$(= $tau_ps/100)
opref=rotdif
# Determine if an external D is being used"
q_ext=""
Diso_ext=""
Dani_ext=""
Drho_ext=""
fittxtstr=""
num_chunks=4
#Bfields="400.133 500.133 600.133 700.133 800.133"
Bfields=600.133
zetaStr=""
bGenTraj=False ; bGenTrajDefault=False
gentrj_default="$script_loc/center-solute-gromacs.bash"
bGenRef=False ; bGenRefDefault=False
genref_default="$script_loc/create-reference-pdb.bash"
bUseExt=False
bDoJw=False ; bDoFits=False
bForce=False
# = = Read and interpret variables."
while [[ $# -gt 0 ]] ; do
    case "$1" in
        -h|--help)
            echo "= = (Doc) = =
This script generates R1, R2, and NOE parameters from MD trajectories. It requires the following programs:
- Python-2.7+ with the following modules:
    - scipy, numpy, mdtraj, transforms3d
    - python also will need to read other helper files included in this workflow package.
- Gromacs for utilities, such as generating solute trajectories from initial MD trajectories.
- PLUMED for the computation of Quaternions from solute trajectories.
It also requires in general the following two files, which can be generated by the script if you are desperate and have a GROMACS TPR file handy.
- A reference coordinate file that defines the zero-rotation of the internal frame.
- A trajectory of the solute from which global rotational motion is derived.
NB:
- The default time units is in ps, following GROMACS conventions.
- For multimeric complexes, you absolutely should make the solute whole yourself by removing periodic-boundaries. Editing the PLUMED script permits you to do this within itself, but neither it nor GROMACS will know how to keep different chains together in the same periodic image.
- It is possible to take multiple simulations and combine their total data. To do this, place each simulation in its own folder, and invoke the -folders argument, this will enable the folder synthesis. The output will not be modified, and so -out will by default write to to the current folder.
  Also note that in this mode, the reference file and plumed script will by default be contained in *each* folder to account for small variations like alternate protonation states. In order to ensure usage of the same file, it is best to provide absolute paths to -refpdb, and -pfile if you have one.

= = (List of arguments:) = =
  = = File-naming and processing = =
  -bForce : Run even when old files exist.
  -out <prefix> : Specify custom output-prefix. (Default: $opref)
  -folders <filename>: Specify that multiple source simulations exists. The given file must contain a list of folders parseable by 'cat \$file' (Default: none)
  -qfile <filename> : Specify custom filename/location for quaternions. (Default: $qfile)
  -pfile <filename> : Specify custom filename/location for PLUMED quaternion script. (Default: $pfile)
  -refpdb <filename> : Specify custom filename/location for reference coordinate used by PLUMED and Python-MDTraj. (Default: $refpdb)
  -vecstorage <string> : Specify how the vector distributions is stored for anisotropic relaxation calculations Histogram|PhiTheta|TextPhiTheta (Default: $vecStorage)
  -expfile <filename> : Specify custom filename/location for experimental R1/R2/NOE. (Default: $expfn)
  -sxtc <filename> : Specify custom filename/location for simulation trajectory used by PLUMED. (Default: $sxtc)
  -xtc_step <N ps> : Explicitly give the time period between successive frames. Otherwise GROMACS will be used to attempt to determine this.
  -genref [\"complete BASH command\"] : Generate solute reference within the script. Optionally replace the default command by giving a complete BASH command as an argument, enclosed in double-quotes \"gmx ... \"
        (Default: $genref $refpdb $tpr)
  -gentrj [\"complete BASH command\"] : Generate solute trajectory within the script. Optionally replace the default command by giving a complete BASH command as an argument.
        (Default: $gentrj $sxtc $tpr)
  -pycmd <python-executable> : Change the python command. (Default: $pycmd)
  -plumed <plumed-executable> : Change the plumed command. (Default: $plumed)
  = = Simulation/Experimental Conditions = =
  -t_mem <time> [ps] : Memory time to cut off computation of auto-correlation & diffusions. Accepts a time unit argument. (Default: $tau_ns ns)
        NB: This is usually based on available trajectory frames and known global tumbling.
  -Temp_MD <Kelvin> : Simulation temperature for Diso correction to experimental conditions. (Default: $T_md K)
  -Temp_Exp <Kelvin> : Experimental temperature for Diso correction to experimental conditions. (Default: $T_exp K)
  -D2O_Exp <decimal> : D2O concentration for Diso correction to experimental conditions. (Default: $c_D2O)
  -Bfields <MHz> [MHz] ... :  A list of Magnetic field strengths to calculation relaxation parameters for. Accepts a time unit argument (Default: $Bfields)
  -fitatoms: Input a custom atom-selection to the python script calculating C(t) in the local frame.
        NB: Please enclose selection in quotation marks. (Default: \"name CA and occupancy > 0\")
  -fit : Conduct fitting to optimise Diso and/or S2 & CSA. Will take some time. Takes as options any of the following:
        Diso, DisoS2, DisoCSA
  -zeta : Add adjustment to S2. (Default: none)
  -Jw : Report the spectral densities as well, for each vector.
  = = External options = =
  -D_ext <Diso> [anisotropy] [rhombicity] : Replace simulation global rotational diffusion with input values, in units of ps^-1. (Default: $Diso_ext $Dani_ext)
        NB: Rhombicity is currently ignored.
  -tau_ext <tau_ext> [ps] : As above, but given as a single global rotational correlation time. Accepts a time unit argument, e.g. as -tau_ext 3.9 ns 
  -q_ext <q_w> <q_x> <q_y> <q_z> : Replace simulation PAF orientation (relative to reference coordinates) with input q. (Default: $q_ext)
"
            exit;;
        -bForce) bForce=True ;;
        -out|-outpref|-opref) opref=$2 ; shift ;;
        -folders) bMulti=True ; folderfile=$2 ; shift ;;
        -multiref) bMultiRef=True ;;
        -qfile) qfile=$2 ; shift ;;
        -pfile) pfile=$2 ; shift ;;
        -refpdb|-reffile) refpdb=$2 ; shift ;;
        -sxtc) sxtc=$2 ; shift ;;
        -xtc_step) xtc_step=$2 ; shift ;;
        -genref) bGenRef=True  ; [[ $# -gt 1 ]] && [[ ${2:0:1} != "-" ]] && { genref="$2" ; bGenRefDefault=False ;  shift ; } ;;
        -gentrj) bGenTraj=True ; [[ $# -gt 1 ]] && [[ ${2:0:1} != "-" ]] && { gentrj="$2" ; bGenTrajDefault=False ; shift ; } ;;
        -pycmd) pycmd=$2 ; shift ;;
        -plumed) plumed=$2 ; shift ;;
        -t_mem)
            temp=$2 ; shift
            [ $2 ] && [[ "${2:0:1}" != "-" ]] && { tFact=$(determine_time_factor $2) ; shift ; } || tFact=1.0
            tau_ps=$(= $temp*$tFact) ; t100=$(= $tau_ps/100) ; tau_ns=$(= $tau_ps/1000)
            echo "= = Set memory time to $tau_ps ps." ;;
        -Temp_MD) T_md=$2 ; shift ;;
        -Temp_Exp) T_exp=$2 ; shift ;;
        -D2O_Exp) c_D2O=$2 ; shift ;;
        -tau_ext)
            temp=$2 ; shift 
            [ $2 ] && [[ "${2:0:1}" != "-" ]] && { tFact=$(determine_time_factor $2) ; shift ; } || tFact=1.0
            Diso_ext=$(= 1.0/[6*$temp*$tFact]) ; bUseExt=True 
            echo "= = Using external global tumbling values: $Diso_ext ps^-1 (from tau_ext)" ;;
        -D_ext)
            Diso_ext=$2 ; shift
            if [[ ${2:0:1} != "-" ]] ; then
                Dani_ext=$2 ; shift
                if [[ ${2:0:1} != "-" ]] ; then
                    Drho_ext=$2 ; shift
                fi
            fi
            bUseExt=True
            echo "= = Using external global tumbling values: $Diso_ext $Dani_ext $Drho_ext"
            ;;
        -q_ext) q_ext="$2 $3 $4 $5" ; shift 4 ;;
        # = = Output related arguments, such at what to calculate and which fields.
        -num_chunks)
            num_chunks=$2 ; shift
            echo "= = Number of chunks in global rotational diffusion."
            ;;
        -Bfields)
            Bfields=""
            while [[ ${2:0:1} != "-" ]] && [[ "$2" != "" ]] ; do
                Bfields="$Bfields $2" ; shift
            done
            echo "= = Calculating at the following magnetic fields: $Bfields [MHz]"
            ;;
        -fitatoms)
            fittxtstr="--fitsel \"$2\"" ; shift ;;
        -fit) bDoFits=True ; fitlist=""
            while [[ ${2:0:1} != "-" ]] && [[ "$2" != "" ]] ; do
                fitlist="$fitlist $2" ; shift
            done
            ;;
        -zeta) zetaStr="--zeta $2" ; shift ;;
        -expfile) expfn=$2 ; shift ;;
        -Jw)  bDoJw=True ;;
        *)
            echo "= = ERROR: Unrecognised argument: $1"
            exit -1
            ;;
    esac
    shift
done

# = = = Sanity checks.
if [[ "$expfn" == "" ]] && [[ "$bDoFits" == "True" ]] ; then
    echo "= = ERROR: -fit selected, but no experimental file has been given!"
    exit -2
fi

outpref=$opref-${tau_ns}ns
#pymode

D_fact=$(convert_Diso 1 $T_md $T_exp $c_D2O)
echo "= = Based on relative simulation-experimental temperature and D2O concentration, determined the Diso conversion factor to be $D_fact"
# = = = Other published data with VHS is taken at 15 deg C, 10% D2O, and Bruker Avance 600+900 MHz.

# Parse folder paths, change variables around where-ever necessary.
if [[ "$bMulti" == "True" ]] ; then
    # Sanity check if any folder paths are absolute, which cannot be used with bMulti
    for file in $sxtc $qfile ; do
        if [[ "${file:0:1}" == "/" ]] ; then
            echo "= = ERROR: Cannot use multiple folder with absolute location of solute trajectories nor quaternion orientations!!"
            echo "    ...offending file: $file"
            exit 1
        fi
    done

    foldlist=$(cat $folderfile)
    qfile_multi=${qfile}-aggregate
    rm -f $qfile_multi

    sxtc_list=""
    for path in $foldlist ; do
        sxtc_list="$sxtc_list ${path}/${sxtc}"
    done
    if [[ "$bMultiRef" == "True" ]] ; then
        refpdb_list=""
        for path in $foldlist ; do
            refpdb_list="$refpdb_list ${path}/${refpdb}"
        done
    fi
#else
#    [[ "${sxtc:0:1}" == "/" ]] && sxtc_list=$sxtc || sxtc_list=${path}/${sxtc}
#    [[ "${refpdb:0:1}" == "/" ]] && refpdb_list=$refpdb || refpdb_list=${path}/${refpdb}
fi

echo "= Step 1: Generating Quaternion Orientation trajectory from MD (colvar-q)..."
# When multiple files are present generate the quaternion for each.
for path in $foldlist ; do
    [[ "${pfile:0:1}" == "/" ]] && pfile_loc=$pfile || pfile_loc=${path}/${pfile}
    [[ "${qfile:0:1}" == "/" ]] && qfile_loc=$qfile || qfile_loc=${path}/${qfile}
    [[ "${tpr:0:1}" == "/" ]] && tpr_loc=$tpr || tpr_loc=${path}/${tpr}
    [[ "${sxtc:0:1}" == "/" ]] && sxtc_loc=$sxtc || sxtc_loc=${path}/${sxtc}
    [[ "$bMultiRef" == "True" ]] && refpdb_loc=${path}/${refpdb} || refpdb_loc=$refpdb

    if [ ! -e $qfile_loc ] ; then
        echo "= = $qfile_loc has not been found. Will construct. Checking for existence of reference trajectory and coordinates.."
        if [[ "$bGenRef" == "True" ]] && [ ! -e $refpdb_loc ] ; then
            [[ "$bGenRefDefault" == "True" ]] && genref_loc="$genref $refpdb_loc $tpr_loc" || genref_loc=$genref
            echo "= = = Running reference coordinate generation..."
            echo "      ...using command: $genref_loc"
            $genref_loc
            assert_file $refpdb_loc
        else
            echo "= = = Not generating reference coordinates."
        fi
        if [[ "$bGenTraj" == "True" ]] && [ ! -e $sxtc_loc ] ; then
            [[ "$bGenTrajDefault" == "True" ]] && gentrj_loc="$gentrj $sxtc_loc $tpr_loc" || gentrj_loc=$gentrj_default
            echo "= = = Running solute trajectory generation..."
            echo "      ...using command: $gentrj_loc"
            $gentrj_loc
            assert_file $sxtc_loc
        else
            echo "= = = Not generating solute trajectories."
        fi
        if [ ! -e $pfile_loc ] ; then
            echo "= = = Given plumed script $pfile_loc is absent. Copying from template."
            sed "s,VAR_QFILE,$qfile_loc,;s,VAR_REFFILE,$refpdb_loc," $pfile_template > $pfile_loc
        fi
        assert_file $sxtc_loc $pfile_loc $refpdb_loc
        if [[ "$xtc_step" == "" ]] ; then
            echo "= = = NB: Using GROMACS to try to detect time steps in xtc. This can be slow, so consider using -xtc_step to skip this step."
            xtc_step=$($gcheck -f $sxtc_loc 2>&1 | grep Step | awk '{print $NF}')
            if [[ "$xtc_step" == "" ]] ; then
                echo "= = ERROR in GROMACS gmxcheck looking for the time period between successive trajectory frames. Consider setting -xtc_step manually."
                exit -1
            fi
            echo "= = = Used GROMACS to determine time-step between frames of $sxtc_loc -- Found to be $xtc_step ps."
        else
            echo "= = = Manually set time-step between frames of $sxtc_loc to $xtc_step ps."
        fi
        echo "= = = Running PLUMED..."
        $plumed driver --mf_xtc $sxtc_loc --plumed $pfile_loc --timestep $xtc_step 2>&1 | tee plumed.log
        echo "= = = PLUMED has been run to generate $qfile_loc, with output in plumed.log"
        assert_file $qfile_loc
    else
        echo " = = = Note: Pre-existing quaternion file found, skipping derivations."
    fi
    # If this is multiple, concatenate into aggregate orient file.
    cat $qfile_loc >> $qfile_multi
done

echo
echo "= Step 2: Generating Global Rotational Diffusion in quaternion notation (aniso_q)..."
# = = Generate global rotdif. This is only one file regardless of whether there is one or multiple sources. = =
[[ "$bMulti" == "True" ]] && \
    { qfile_loc=$qfile_multi ; q_cmd=calculate-dq-distribution-multi.py ; } || \
    { qfile_loc=$qfile ; q_cmd=calculate-dq-distribution.py ; }

if [ ! -e ${outpref}-aniso_q.dat ] ; then
    $pycmd $script_loc/$q_cmd \
        --iso --aniso -f $qfile_loc \
        -o ${outpref} \
        --mindt $t100 --skip $t100 --maxdt $tau_ps \
        --num_chunk $num_chunks
    assert_file ${outpref}-aniso_q.dat
else
    echo "= = = Note: Pre-existing global rotational diffusion data found in ${outpref}-aniso_q.dat, skipping derivations."
fi

q_loc=$(head -n 1 ${outpref}-aniso_q.dat | awk '{print $2, $3, $4, $5}')
# Check if external quaternions have been called
if [[ "$q_ext" == "" ]] ; then
    echo "= = Using quaternion from 1st dt-interval of trajectory as PAF"
    quat=$q_loc
else
    quat=$q_ext
    echo "= = Ignoring simulation trajectory quaternion: $q_loc"
fi
echo "= = Quaternion used: $quat"

# Determine axisymmetric orientation, using the assumption
# that  D_x < D_y < D_z always holds. Therefore, When D_ani is < 1,
# the unique axis points instead along Dx.
# This preserves the quaternion orientation definition to not worry about axis switching.
# This will also be accounted for in the relaxation calculations.
Diso_loc=$(head -n 20 ${outpref}-aniso2.dat | grep Diso | awk -v fact=$D_fact '{print $(NF-3)*1e-12*fact}')
DaniL_loc=$(head -n 20 ${outpref}-aniso2.dat | grep Dani_L | awk '{print $(NF-2)}')
DrhoL_loc=$(head -n 20 ${outpref}-aniso2.dat | grep Drho_L | awk '{print $(NF-2)}')
DaniS_loc=$(head -n 20 ${outpref}-aniso2.dat | grep Dani_S | awk '{print $(NF-2)}')
DrhoS_loc=$(head -n 20 ${outpref}-aniso2.dat | grep Drho_S | awk '{print $(NF-2)}')

symmaxis=$(echo $DrhoL_loc $DrhoS_loc | awk '{if ($1<1.0) {
    print "z"
} else if ($2<1.0) {
    print "x"
} else {
    print "ERROR"
}
}')
if [[ "$symmaxis" == "z" ]] ; then
    echo "= = = Long axis ellipsoid detected, pointing along Dz."
    Dani_loc=$DaniL_loc
elif [[ "$symmaxis" == "x" ]] ; then
    echo "= = = Short axis ellipsoid detected, pointing along Dx."
    Dani_loc=$DaniS_loc
else
    echo "= = = ERROR: neither Drho values are less than one in the global rotation diffusion calculation. This is not possible, therefore aborting."
    exit 1
fi

# If an external number is given, then assume that this is all accoutned for.
# Use the fact that Dani<1 will inevitably means D_x becomes the unique axis.
echo "= = Local symmtop rotational diffusion (@ expt conditions): $Diso_loc $Dani_loc"
[[ "$Diso_ext" != "" ]] && Diso=$Diso_ext || Diso=$Diso_loc
[[ "$Dani_ext" != "" ]] && Dani=$Dani_ext || Dani=$Dani_loc

echo
echo "= Step 3: Generating Local Motion data..."
# = = Generate local autocorrelation and vector distributions.

if [[ "$sxtc_list" == "" ]] ; then
    sxtc_list=$sxtc_loc
fi

case $vecStorage in
    Histogram)
        vecDistFile=${outpref}_vecHistogram.npz
        vecDistArgs="--vecHist --binary"
        ;;
    PhiTheta)
        vecDistFile=${outpref}_vecPhiTheta.npz
        vecDistArgs="--vecDist --binary"
        ;;
    TextPhiTheta)
        vecDistFile=${outpref}_vecPhiTheta.dat
        vecDistArgs="--vecDist"
        ;;
    *)
        echo "= = = ERROR: Argument for vector storage not understood! $vecStorage is not Histogram | PhiTheta | TextPhiTheta"
        exit 1
esac

[[ "$bMultiRef" == "True" ]] && refpdb_loc=$refpdb_list || refpdb_loc=$refpdb
# echo "= = (Part 1): Obtaining XH-vector distribution in PAF frame in polar coordinates (PhiTheta)..."
echo "= = (Part 1 and 2): Obtaining XH-vector distribution in PAF frame and binning them as histograms..."
echo "= = (Part 1 and 2): Obtaining XH-vector auto-correlation in both global and local frame (Ctint)... "
if [ ! -e $vecDistFile ] || [ ! -e ${outpref}_Ctint.dat ] ; then
    $pycmd \
        $script_loc/calculate-Ct-from-traj.py \
        -s $refpdb_loc -f $sxtc_list \
        --tau $tau_ps -o ${outpref} \
        --vecRot "$quat" $fittxtstr \
        $vecDistArgs --vecAvg --S2 --Ct
else
    echo " = = = Note: Pre-existing files for both vector distribution and internal motions have been found, skipping derivations."
fi

echo "= = (Part 3): Fitting the auto-correlations in the local frame (fittedCt)..."
if [ ! -e ${outpref}_fittedCt.dat ] ; then
    $pycmd \
        $script_loc/calculate-fitted-Ct.py \
        -f ${outpref}_Ctint.dat \
        -o ${outpref}
else
    echo " = = = Note: Pre-existing fitted-Ct file found, skipping derivations."
fi

echo
echo "= Step 4: Computing relaxations for B: $Bfields ..."
for Bfield in $Bfields ; do
    of=${Bfield%.*}
    if [ ! -e ${outpref}-${of}_R2.dat ] ; then
        $pycmd $script_loc/calculate-relaxations-from-Ct.py \
            -f ${outpref}_fittedCt.dat \
            -o ${outpref}-$of \
            --distfn $vecDistFile \
            -F ${Bfield}e6 \
            --tu ps $zetaStr \
            --D "$Diso $Dani"
    else
        echo " = = = Note: R1/R2/NOE-calculations at $Bfield has already been done. Skipping."
    fi
    if [[ "$bDoJw" == "True" ]] ; then
        if [ ! -e ${outpref}-${of}_Jw.dat ] ; then
        $pycmd $script_loc/calculate-relaxations-from-Ct.py \
            -f ${outpref}_fittedCt.dat \
            -o ${outpref}-$of \
            --distfn $vecDistFile \
            -F ${Bfield}e6 \
            --tu ps --Jomega $zetaStr \
            --D "$Diso $Dani"
        else
            echo " = = = Note: Jw-calculations at $Bfield has already been done. Skipping."
        fi
    fi
    if [[ "$bDoFits" == "True" ]] ; then
      for optmode in $fitlist ; do
        if [ "$bForce" == "True" ] || [ ! -e ${outpref}-${of}-opt${optmode}_R2.dat ] ; then
            $pycmd $script_loc/calculate-relaxations-from-Ct.py \
                -f ${outpref}_fittedCt.dat \
                -o ${outpref}-$of-opt${optmode} \
                --distfn $vecDistFile \
                -F ${Bfield}e6 \
                --tu ps $zetaStr \
                --D "$Diso $Dani" \
                --expfn $expfn \
                --opt $optmode
        else
            echo " = = = Note: Fit $optmode-calculations at $Bfield has already been done. Skipping."
        fi
      done
    fi
done
